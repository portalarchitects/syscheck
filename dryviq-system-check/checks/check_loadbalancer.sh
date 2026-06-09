#!/bin/bash
# LoadBalancer + Ingress readiness (AKS/EKS). DryvIQ is reached through an
# ingress/LB; provisioning frequently fails on subnet/SNAT exhaustion, missing
# cloud annotations, or a missing ingress controller. This provisions a real
# Service type=LoadBalancer, waits for an external address, then tears it down.
set -u
set -o pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

if [[ "${ENVIRONMENT:-}" != "aks" && "${ENVIRONMENT:-}" != "eks" ]]; then
  print_status SKIP "LoadBalancer/Ingress provisioning check runs only for AKS/EKS."
  exit 0
fi

LB_TIMEOUT_SECS="${PREFLIGHT_LB_TIMEOUT_SECS:-180}"
NS="$(new_probe_namespace dryviq-preflight-lb)"
FAIL=0
cleanup() { kubectl delete ns "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

# 1) Ingress controller present?
ICLASSES=$(kubectl get ingressclass -o name 2>/dev/null | sed 's|ingressclass.networking.k8s.io/||' | tr '\n' ' ')
if [[ -n "${ICLASSES// }" ]]; then
  print_status PASS "IngressClass(es) present: ${ICLASSES}"
else
  print_status WARN "No IngressClass found. If DryvIQ is exposed via Ingress, install an ingress controller (e.g. ingress-nginx) first."
fi

# 2) Live LoadBalancer provisioning
kubectl create ns "$NS" >/dev/null 2>&1 || true
cat <<YAML | kubectl -n "$NS" apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Service
metadata:
  name: lb-probe
spec:
  type: LoadBalancer
  selector:
    app: nonexistent-preflight
  ports:
  - port: 80
    targetPort: 80
YAML

print_status INFO "Provisioning a temporary LoadBalancer (this can take 1-3 minutes)..."
got_addr=0
deadline=$(( $(date +%s) + LB_TIMEOUT_SECS ))
while [[ $(date +%s) -lt $deadline ]]; do
  addr=$(kubectl -n "$NS" get svc lb-probe -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  if [[ -n "$addr" ]]; then got_addr=1; break; fi
  sleep 10
done

if [[ "$got_addr" -eq 1 ]]; then
  print_status PASS "LoadBalancer received an external address ($addr) — cloud LB provisioning works."
else
  print_status FAIL "LoadBalancer did not get an external address within ${LB_TIMEOUT_SECS}s."
  kubectl -n "$NS" describe svc lb-probe 2>/dev/null | grep -iA3 events || true
  print_status INFO "Common causes: subnet/public-IP exhaustion, SNAT limits, missing cloud-provider annotations, or restricted outbound type (AKS UDR)."
  FAIL=1
fi

cleanup
trap - EXIT

if [[ "$FAIL" -eq 0 ]]; then
  exit 0
else
  exit 1
fi

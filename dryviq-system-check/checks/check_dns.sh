#!/bin/bash
# DNS health: the #1 cause of mysterious cluster failures.
# Checks CoreDNS (or kube-dns) pods are healthy, then verifies in-cluster
# service resolution and external resolution from inside a pod.
set -u
set -o pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

READINESS_TIMEOUT="${PREFLIGHT_READINESS_TIMEOUT:-120s}"
CLIENT_IMAGE="${PREFLIGHT_CLIENT_IMAGE:-busybox:1.36}"
NS="$(new_probe_namespace dryviq-preflight-dns)"

FAIL=0
cleanup() { kubectl delete ns "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

# 1) Cluster DNS pods (CoreDNS or kube-dns) in kube-system
DNS_PODS=$(kubectl -n kube-system get pods -l k8s-app=kube-dns --no-headers 2>/dev/null)
if [[ -z "$DNS_PODS" ]]; then
  # Some distros label CoreDNS differently
  DNS_PODS=$(kubectl -n kube-system get pods 2>/dev/null | grep -iE 'coredns|kube-dns' || true)
fi

if [[ -z "$DNS_PODS" ]]; then
  print_status WARN "Could not locate CoreDNS/kube-dns pods in kube-system (non-standard DNS setup?)."
else
  total=$(echo "$DNS_PODS" | grep -c . || true)
  running=$(echo "$DNS_PODS" | grep -c -iE 'Running' || true)
  if [[ "$running" -ge 1 && "$running" -eq "$total" ]]; then
    print_status PASS "Cluster DNS healthy ($running/$total pods Running)."
  elif [[ "$running" -ge 1 ]]; then
    print_status WARN "Cluster DNS partially healthy ($running/$total pods Running)."
  else
    print_status FAIL "No cluster DNS pods are Running ($running/$total)."
    FAIL=1
  fi
  if [[ "$total" -lt 2 ]]; then
    print_status WARN "Only $total DNS replica(s); a single CoreDNS pod is a single point of failure under load."
  fi
fi

# 2) Resolution tests from a pod
kubectl create ns "$NS" >/dev/null 2>&1 || true
cat <<YAML | kubectl -n "$NS" apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: dns-probe
spec:
  containers:
  - name: c
    image: ${CLIENT_IMAGE}
    imagePullPolicy: IfNotPresent
    command: ["sh","-c","sleep 3600"]
    securityContext:
      allowPrivilegeEscalation: false
  restartPolicy: Never
YAML

if ! kubectl -n "$NS" wait --for=condition=Ready pod/dns-probe --timeout="$READINESS_TIMEOUT" >/dev/null 2>&1; then
  print_status FAIL "DNS probe pod did not become Ready; cannot run resolution tests."
  exit 1
fi

pexec() { kubectl -n "$NS" exec dns-probe -- sh -c "$1" >/dev/null 2>&1; }

# In-cluster service resolution
if pexec "nslookup kubernetes.default.svc.cluster.local"; then
  print_status PASS "In-cluster service DNS resolves (kubernetes.default.svc.cluster.local)."
else
  print_status FAIL "In-cluster service DNS FAILED (kubernetes.default.svc.cluster.local). Service discovery is broken."
  kubectl -n "$NS" exec dns-probe -- sh -c "cat /etc/resolv.conf" 2>/dev/null | sed 's/^/    /' || true
  FAIL=1
fi

# External resolution
if pexec "nslookup api.portalarchitects.com"; then
  print_status PASS "External DNS resolves from pods (api.portalarchitects.com)."
else
  print_status FAIL "External DNS FAILED from pods (api.portalarchitects.com). Upstream resolver/forwarder blocked?"
  FAIL=1
fi

cleanup
trap - EXIT

if [[ "$FAIL" -eq 0 ]]; then
  print_status PASS "DNS is healthy (cluster + external)."
  exit 0
else
  print_status FAIL "DNS problems detected (see above)."
  exit 1
fi

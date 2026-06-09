#!/bin/bash
# External egress reachability check.
# - Honors corporate proxy env (HTTP(S)_PROXY/NO_PROXY) on the host path.
# - Classifies failures (DNS vs TCP vs TLS interception) from curl exit codes.
# - Optional tooling endpoints WARN instead of failing the whole run.
set -u
set -o pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

CURL_MAX_TIME="${PREFLIGHT_CURL_MAX_TIME:-15}"

# Classify a curl exit code into an actionable hint.
curl_hint() {
  case "$1" in
    6)  echo "DNS resolution failed (cannot resolve host)." ;;
    7)  echo "TCP connect failed (firewall/route/proxy blocking 443?)." ;;
    28) echo "Timed out (slow link, proxy, or silently dropped)." ;;
    35) echo "TLS handshake failed (port open but no/!TLS — proxy intercept?)." ;;
    60) echo "TLS certificate not trusted (SSL inspection / corporate CA in path?)." ;;
    *)  echo "curl exit code $1." ;;
  esac
}

# --- Proxy awareness (host path) ---
if [[ -n "${HTTPS_PROXY:-${https_proxy:-}}" || -n "${HTTP_PROXY:-${http_proxy:-}}" ]]; then
  print_status INFO "Proxy env detected (HTTPS_PROXY=${HTTPS_PROXY:-${https_proxy:-}} NO_PROXY=${NO_PROXY:-${no_proxy:-<unset>}}). Egress will be tested through it on the host path."
fi

# Build endpoint sets. K3s install deps only matter on-prem.
REQUIRED=()
while IFS= read -r e; do [[ -n "$e" ]] && REQUIRED+=("$e"); done < <(required_egress_endpoints)
if [[ "${ENVIRONMENT:-}" == "k3s" ]]; then
  while IFS= read -r e; do [[ -n "$e" ]] && REQUIRED+=("$e"); done < <(k3s_egress_endpoints)
fi
OPTIONAL=()
while IFS= read -r e; do [[ -n "$e" ]] && OPTIONAL+=("$e"); done < <(optional_egress_endpoints)

FAIL=0

# --- In-cluster path (AKS/EKS): test from a pod, since that is what really pulls images ---
if [[ "${ENVIRONMENT:-}" == "aks" || "${ENVIRONMENT:-}" == "eks" ]]; then
  NS="$(new_probe_namespace dryviq-preflight-egress)"
  POD="net-check"
  IMAGE="$(in_cluster_image)"

  cleanup() { kubectl delete ns "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
  trap cleanup EXIT

  kubectl create ns "$NS" >/dev/null 2>&1 || true
  kubectl run "$POD" --image="$IMAGE" --restart=Never -n "$NS" -- sleep 3600 >/dev/null 2>&1

  if ! kubectl wait --for=condition=Ready pod/"$POD" -n "$NS" --timeout=60s >/dev/null 2>&1; then
    print_status FAIL "Diagnostic pod did not start (image: $IMAGE)."
    print_status INFO "If the pod is stuck on ImagePullBackOff, the cluster cannot pull from the public registry — that itself is the egress problem to fix (proxy/firewall/registry mirror)."
    kubectl -n "$NS" describe pod/"$POD" 2>/dev/null | grep -A3 -iE 'events|failed|pull' || true
    exit 1
  fi

  test_endpoint_incluster() {
    local ep="$1"
    kubectl exec -n "$NS" "$POD" -- curl -sS --max-time "$CURL_MAX_TIME" -o /dev/null --head "https://$ep" 2>/dev/null
    return $?
  }

  for ep in "${REQUIRED[@]}"; do
    if test_endpoint_incluster "$ep"; then
      print_status PASS "Reachable in-cluster: https://$ep"
    else
      print_status FAIL "NOT reachable in-cluster: https://$ep — $(curl_hint "$?")"
      FAIL=1
    fi
  done
  for ep in "${OPTIONAL[@]}"; do
    if test_endpoint_incluster "$ep"; then
      print_status PASS "Reachable in-cluster (optional): https://$ep"
    else
      print_status WARN "Optional endpoint not reachable in-cluster: https://$ep — $(curl_hint "$?")"
    fi
  done

  cleanup
  trap - EXIT
else
  # --- Host path (K3s / generic): test directly, honoring proxy env ---
  test_endpoint_host() {
    local ep="$1"
    curl -sS --max-time "$CURL_MAX_TIME" -o /dev/null --head "https://$ep" 2>/dev/null
    return $?
  }

  for ep in "${REQUIRED[@]}"; do
    if test_endpoint_host "$ep"; then
      print_status PASS "Reachable: https://$ep"
    else
      print_status FAIL "NOT reachable: https://$ep — $(curl_hint "$?")"
      FAIL=1
    fi
  done
  for ep in "${OPTIONAL[@]}"; do
    if test_endpoint_host "$ep"; then
      print_status PASS "Reachable (optional): https://$ep"
    else
      print_status WARN "Optional endpoint not reachable: https://$ep — $(curl_hint "$?")"
    fi
  done
fi

if [[ $FAIL -ne 0 ]]; then
  print_status FAIL "One or more required external endpoints were not reachable."
  exit 1
else
  print_status PASS "All required external endpoints reachable."
fi

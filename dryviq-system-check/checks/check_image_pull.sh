#!/bin/bash
# Registry pull-path check. A HEAD to the registry host on 443 does not prove a
# pull works: ACR serves the Docker v2 API on the registry host and streams
# layers from *.blob.core.windows.net, with a token handshake in between.
# This validates the v2 API responds and (optionally) does a live pod pull.
set -u
set -o pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

READINESS_TIMEOUT="${PREFLIGHT_READINESS_TIMEOUT:-120s}"
CURL_MAX_TIME="${PREFLIGHT_CURL_MAX_TIME:-15}"
REGISTRY="${PREFLIGHT_REGISTRY:-dryviq.azurecr.io}"
BLOB_HOST="${PREFLIGHT_BLOB_HOST:-dryviq.eastus.data.azurecr.io}"
# Optional: a fully-qualified image the cluster has creds for, to do a live pull.
TEST_IMAGE="${PREFLIGHT_TEST_IMAGE:-}"
PULL_SECRET="${PREFLIGHT_PULL_SECRET:-}"

NS="$(new_probe_namespace dryviq-preflight-pull)"
FAIL=0
cleanup() { kubectl delete ns "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

# --- Where do we run the curl from? In-cluster for managed clusters, else host. ---
run_curl() { # args: url ; echoes HTTP status code or 000
  local url="$1" out
  if [[ "${ENVIRONMENT:-}" == "aks" || "${ENVIRONMENT:-}" == "eks" ]]; then
    out=$(kubectl -n "$NS" exec curl-probe -- curl -s -o /dev/null -w '%{http_code}' --max-time "$CURL_MAX_TIME" "$url" 2>/dev/null)
  else
    out=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$CURL_MAX_TIME" "$url" 2>/dev/null)
  fi
  echo "${out:-000}"
}

if [[ "${ENVIRONMENT:-}" == "aks" || "${ENVIRONMENT:-}" == "eks" ]]; then
  kubectl create ns "$NS" >/dev/null 2>&1 || true
  kubectl -n "$NS" run curl-probe --image="$(in_cluster_image)" --restart=Never -- sleep 3600 >/dev/null 2>&1
  if ! kubectl -n "$NS" wait --for=condition=Ready pod/curl-probe --timeout=60s >/dev/null 2>&1; then
    print_status FAIL "curl probe pod did not start — the cluster likely cannot pull $(in_cluster_image) from the public registry (that is the egress problem to fix)."
    exit 1
  fi
fi

# 1) Registry Docker v2 API. 200 or 401 both mean "reachable + TLS OK".
code=$(run_curl "https://${REGISTRY}/v2/")
case "$code" in
  200|401|403)
    print_status PASS "Registry v2 API reachable: https://${REGISTRY}/v2/ (HTTP $code)." ;;
  000)
    print_status FAIL "Registry ${REGISTRY} unreachable (DNS/TCP/TLS). Image pulls will fail."
    FAIL=1 ;;
  *)
    print_status WARN "Registry ${REGISTRY}/v2/ returned unexpected HTTP $code." ;;
esac

# 2) Blob/layer host (ACR streams layers from blob storage).
code=$(run_curl "https://${BLOB_HOST}/")
case "$code" in
  000)
    print_status FAIL "Layer/blob host ${BLOB_HOST} unreachable. Layer downloads will fail even if the manifest resolves."
    FAIL=1 ;;
  *)
    print_status PASS "Layer/blob host reachable: https://${BLOB_HOST}/ (HTTP $code)." ;;
esac

# 3) Optional live pull of a real image the cluster has credentials for.
if [[ -n "$TEST_IMAGE" ]]; then
  [[ "${ENVIRONMENT:-}" != "aks" && "${ENVIRONMENT:-}" != "eks" ]] && kubectl create ns "$NS" >/dev/null 2>&1 || true
  secret_line=""
  [[ -n "$PULL_SECRET" ]] && secret_line="  imagePullSecrets: [{name: ${PULL_SECRET}}]"
  cat <<YAML | kubectl -n "$NS" apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: pull-test
spec:
${secret_line}
  containers:
  - name: c
    image: ${TEST_IMAGE}
    command: ["sh","-c","sleep 30"]
  restartPolicy: Never
YAML
  if kubectl -n "$NS" wait --for=condition=Ready pod/pull-test --timeout="$READINESS_TIMEOUT" >/dev/null 2>&1; then
    print_status PASS "Live image pull succeeded: ${TEST_IMAGE}"
  else
    print_status FAIL "Live image pull FAILED for ${TEST_IMAGE} (auth/network/registry)."
    kubectl -n "$NS" describe pod pull-test 2>/dev/null | grep -iA2 -E 'failed|pull|backoff' || true
    FAIL=1
  fi
else
  print_status INFO "Set PREFLIGHT_TEST_IMAGE (and PREFLIGHT_PULL_SECRET if private) to also do a live in-cluster pull of a real DryvIQ image."
fi

cleanup
trap - EXIT

if [[ "$FAIL" -eq 0 ]]; then
  print_status PASS "Registry pull path is functional."
  exit 0
else
  print_status FAIL "Registry pull path has problems (see above)."
  exit 1
fi

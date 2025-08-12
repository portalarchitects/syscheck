#!/bin/bash
# Cloud DB connectivity probe (AKS/EKS): verifies in-cluster TCP reachability to Postgres endpoints.
# Uses BusyBox + nc for portability. No auth attempted; TCP only.

set -u
set -o pipefail

print_status() {
  local status="$1"; shift
  case "$status" in
    PASS) color='\033[0;32m' ;;
    WARN) color='\033[1;33m' ;;
    FAIL) color='\033[0;31m' ;;
    SKIP) color='\033[0;34m' ;;
    INFO) color='\033[0;36m' ;;
    *)    color='\033[0m' ;;
  esac
  echo -e "${color}[$status]\033[0m $*"
}

# Only for cloud runs
if [[ "${ENVIRONMENT:-}" != "aks" && "${ENVIRONMENT:-}" != "eks" ]]; then
  print_status SKIP "Cloud DB connectivity check runs only for AKS/EKS."
  exit 0
fi

NS="dryviq-preflight-db"
READINESS_TIMEOUT="${PREFLIGHT_READINESS_TIMEOUT:-180s}"
# Per-endpoint connect timeout (seconds)
CONNECT_TIMEOUT="${PREFLIGHT_DB_TIMEOUT_SECS:-15}"
CLIENT_IMAGE="${PREFLIGHT_CLIENT_IMAGE:-busybox:1.36}"

FAIL=0

cleanup() {
  # Fast, non-blocking teardown
  timeout 10 kubectl -n "$NS" delete pod db-probe --ignore-not-found --wait=false >/dev/null 2>&1 || true
  timeout 10 kubectl delete ns "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'rc=$?; if [[ $rc -ne 0 ]]; then print_status FAIL "Unexpected error in DB connectivity check (exit $rc)."; exit 1; fi' ERR

# Collect endpoints: env -> (optional) prompt -> (optional) config file
RAW_ENDPOINTS="${DB_ENDPOINTS:-}"
if [[ -z "$RAW_ENDPOINTS" ]]; then
  # Look for a config file if present
  if [[ -f "./config/db_endpoints.txt" ]]; then
    RAW_ENDPOINTS="$(tr '\n' ' ' < ./config/db_endpoints.txt)"
  fi
fi
if [[ -z "$RAW_ENDPOINTS" ]]; then
  # Interactive fallback
  echo -n "Enter one or more DB endpoints (host[:port]) separated by spaces (or press Enter to skip): "
  read -r RAW_ENDPOINTS || true
fi

# Normalize endpoints: split on space or comma; default port 5432
ENDPOINTS=()
if [[ -n "$RAW_ENDPOINTS" ]]; then
  # shellcheck disable=SC2206
  TOKENS=(${RAW_ENDPOINTS//,/ })
  for t in "${TOKENS[@]}"; do
    t="${t//[[:space:]]/}"
    [[ -z "$t" ]] && continue
    if [[ "$t" == *:* ]]; then
      host="${t%%:*}"
      port="${t##*:}"
    else
      host="$t"
      port="5432"
    fi
    ENDPOINTS+=("${host}:${port}")
  done
fi

if [[ ${#ENDPOINTS[@]} -eq 0 ]]; then
  print_status WARN "No DB endpoints provided; skipping DB connectivity check."
  exit 0
fi

# Namespace + probe pod
kubectl create ns "$NS" >/dev/null 2>&1 || true

cat <<YAML | kubectl -n "$NS" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: db-probe
spec:
  containers:
  - name: client
    image: ${CLIENT_IMAGE}
    imagePullPolicy: IfNotPresent
    command: ["sh","-c","sleep 3600"]
    securityContext:
      allowPrivilegeEscalation: false
  restartPolicy: Never
YAML

if ! kubectl -n "$NS" wait --for=condition=Ready --timeout="$READINESS_TIMEOUT" pod/db-probe >/dev/null 2>&1; then
  print_status FAIL "db-probe pod did not become Ready within ${READINESS_TIMEOUT}."
  kubectl -n "$NS" describe pod/db-probe || true
  print_status INFO "If nodes are tainted, schedule a temporary untainted pool or add tolerations."
  exit 1
fi

PROBE_POD="db-probe"

# Helper: run in pod with quiet stdout/stderr unless VERBOSE is set
pexec_q() {
  # quiet by default
  kubectl -n "$NS" exec "$PROBE_POD" -- sh -c "$1" >/dev/null 2>&1
}
pexec_show() {
  kubectl -n "$NS" exec "$PROBE_POD" -- sh -c "$1"
}

# Diagnostics upfront (printed in INFO so they show in summary if useful)
if pexec_q "true"; then
  print_status INFO "Probe pod DNS config:" 
  pexec_show "echo '--- /etc/resolv.conf ---'; cat /etc/resolv.conf 2>/dev/null || true"
fi

# Ensure nc exists in the image (busybox has it). If not, fallback to /dev/tcp
HAS_NC=0
if pexec_q "command -v nc"; then HAS_NC=1; fi

for ep in "${ENDPOINTS[@]}"; do
  host="${ep%%:*}"
  port="${ep##*:}"

  # DNS check: prefer busybox nslookup, fallback to ping -c1
  if pexec_q "nslookup ${host} >/dev/null 2>&1"; then
    : # ok
  elif pexec_q "ping -c1 -W1 ${host} >/dev/null 2>&1"; then
    : # ok
  else
    print_status FAIL "DNS/host resolution failed for ${host} from inside the cluster."
    # Print a quick lookup attempt for context
    pexec_show "echo; echo 'nslookup ${host}:'; nslookup ${host} 2>&1 || true"
    FAIL=1
    continue
  fi

  # TCP connect test
  if [[ $HAS_NC -eq 1 ]]; then
    if pexec_q "timeout ${CONNECT_TIMEOUT} nc -vz -w ${CONNECT_TIMEOUT} ${host} ${port}"; then
      print_status PASS "Reachable: ${host}:${port} (in-cluster)"
    else
      print_status FAIL "Cannot connect to ${host}:${port} from inside the cluster (timeout=${CONNECT_TIMEOUT}s)."
      echo "  Hints:"
      echo "   • Verify NSG/Security Group / firewall rules allow egress from nodes to ${host}:${port}."
      echo "   • If Azure Flexible Server is PRIVATE, ensure VNet integration + privatelink DNS are configured."
      echo "   • If PUBLIC, ensure server firewall allows your node public egress IP range."
      FAIL=1
    fi
  else
    # Fallback using /dev/tcp (bash-only; busybox sh may not support), try wget as last resort
    if pexec_q "timeout ${CONNECT_TIMEOUT} sh -c ': > /dev/tcp/${host}/${port}'"; then
      print_status PASS "Reachable: ${host}:${port} (in-cluster)"
    else
      if pexec_q "timeout ${CONNECT_TIMEOUT} wget -qO- --spider tcp://${host}:${port}"; then
        print_status PASS "Reachable: ${host}:${port} (in-cluster)"
      else
        print_status FAIL "Cannot connect to ${host}:${port} from inside the cluster (timeout=${CONNECT_TIMEOUT}s)."
        FAIL=1
      fi
    fi
  fi
done

# Cleanup (non-blocking via trap)
if [[ "$FAIL" -eq 0 ]]; then
  print_status PASS "All provided DB endpoints are reachable from inside the cluster."
  exit 0
else
  print_status FAIL "One or more DB endpoints were not reachable."
  exit 1
fi

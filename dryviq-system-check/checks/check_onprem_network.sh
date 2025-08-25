#!/bin/bash
# On-prem (K3s) connectivity checks using agnhost HTTP only (no tcp-port flag).

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

# Only for on-prem runs
if [[ "${ENVIRONMENT:-}" != "k3s" ]]; then
  print_status SKIP "On-prem intra-cluster connectivity check runs only for K3s."
  exit 0
fi

NS="dryviq-preflight-net"
READINESS_TIMEOUT="${PREFLIGHT_READINESS_TIMEOUT:-180s}"
HTTP_TIMEOUT="${PREFLIGHT_HTTP_TIMEOUT:-120}"   # seconds for each wget call
SERVER_IMAGE="${PREFLIGHT_SERVER_IMAGE:-registry.k8s.io/e2e-test-images/agnhost:2.45}"
CLIENT_IMAGE="${PREFLIGHT_CLIENT_IMAGE:-registry.k8s.io/e2e-test-images/agnhost:2.45}"

FAIL=0
cleanup() {
  kubectl delete ns "$NS" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'rc=$?; if [[ $rc -ne 0 ]]; then print_status FAIL "Unexpected error in on-prem connectivity check (exit $rc)."; exit 1; fi' ERR

# --- Select nodes ---
PRIMARY_NODE="$(kubectl get nodes -l 'node-role.kubernetes.io/control-plane' -o name 2>/dev/null | sed 's|node/||' | head -1 || true)"
if [[ -z "$PRIMARY_NODE" ]]; then
  PRIMARY_NODE="$(kubectl get nodes -o name 2>/dev/null | sed 's|node/||' | head -1 || true)"
fi

SECONDARY_NODE="$(kubectl get nodes -l kubernetes.io/hostname=worker1 -o name 2>/dev/null | sed 's|node/||' | grep -x 'worker1' || true)"
if [[ -z "$SECONDARY_NODE" ]]; then
  SECONDARY_NODE="$(kubectl get nodes -l kubernetes.io/hostname=worker1 -o name 2>/dev/null | sed 's|node/||' | head -1 || true)"
fi

SINGLE_NODE=0
if [[ -z "$SECONDARY_NODE" ]]; then
  SECONDARY_NODE="$PRIMARY_NODE"
  SINGLE_NODE=1
  print_status WARN "No 'worker1' (nodeType=worker) found. Using PRIMARY node; cross-node overlay path not validated."
fi

if [[ -z "$PRIMARY_NODE" ]]; then
  print_status FAIL "Could not determine a control-plane node for testing."
  exit 1
fi

# --- tolerations list items (no 'tolerations:' key yet) ---
node_toleration_items() {
  local node="$1"
  kubectl get node "$node" -o jsonpath='{range .spec.taints[*]}- key: "{.key}"{"\n"}  operator: "Exists"{"\n"}  effect: "{.effect}"{"\n"}{end}' 2>/dev/null || true
}
PRIMARY_TOL_ITEMS="$(node_toleration_items "$PRIMARY_NODE")"
SECONDARY_TOL_ITEMS="$(node_toleration_items "$SECONDARY_NODE")"
WORKER_TOL_ITEM='- key: "dedicated"
  operator: "Equal"
  value: "worker"
  effect: "NoExecute"'

indent4() { sed 's/^/    /'; }

# --- Namespace ---
kubectl create ns "$NS" >/dev/null 2>&1 || true

# --- Server pod on PRIMARY_NODE (hostNetwork=true). Serve HTTP on 9100 only. ---
{
cat <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: net-server
  labels:
    app: net-server
spec:
YAML
if [[ -n "$PRIMARY_TOL_ITEMS" ]]; then
  echo "  tolerations:"
  echo "$PRIMARY_TOL_ITEMS" | indent4
fi
cat <<YAML
  nodeName: ${PRIMARY_NODE}
  hostNetwork: true
  containers:
  - name: server
    image: ${SERVER_IMAGE}
    imagePullPolicy: IfNotPresent
    command: ["sh","-c","/agnhost netexec --http-port=9100"]
    securityContext:
      allowPrivilegeEscalation: false
  restartPolicy: Never
YAML
} | kubectl -n "$NS" apply -f - >/dev/null

# --- Client pod on SECONDARY_NODE (prefer worker1), pin with nodeSelector + tolerations ---
{
cat <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: net-client
spec:
  nodeSelector:
    nodeType: worker
YAML
echo "  tolerations:"
# explicit worker toleration
echo "$WORKER_TOL_ITEM" | indent4
# dynamic node taints (may duplicate; harmless)
if [[ -n "$SECONDARY_TOL_ITEMS" ]]; then
  echo "$SECONDARY_TOL_ITEMS" | indent4
fi
cat <<YAML
  nodeName: ${SECONDARY_NODE}
  containers:
  - name: client
    image: ${CLIENT_IMAGE}
    imagePullPolicy: IfNotPresent
    command: ["sh","-c","sleep 3600"]
    securityContext:
      allowPrivilegeEscalation: false
  restartPolicy: Never
YAML
} | kubectl -n "$NS" apply -f - >/dev/null

# --- ClusterIP Service to net-server:9100 ---
cat <<'YAML' | kubectl -n "$NS" apply -f - >/dev/null
apiVersion: v1
kind: Service
metadata:
  name: net-svc
spec:
  selector:
    app: net-server
  ports:
  - name: app
    port: 9100
    targetPort: 9100
YAML

# --- Readiness + diagnostics ---
describe_fail_dump() {
  local pod="$1"
  echo "------ DESCRIBE $pod ------"
  kubectl -n "$NS" describe "pod/$pod" || true
  echo "------ RECENT EVENTS ------"
  kubectl -n "$NS" get events --sort-by=.lastTimestamp | tail -n 50 || true
}

wait_ready_or_fail() {
  local pod="$1"
  if ! kubectl -n "$NS" wait --for=condition=Ready --timeout="$READINESS_TIMEOUT" "pod/$pod" >/dev/null 2>&1; then
    print_status FAIL "$pod did not become Ready within ${READINESS_TIMEOUT}."
    describe_fail_dump "$pod"
    FAIL=1
    return 1
  fi
  return 0
}

wait_ready_or_fail net-server || true
wait_ready_or_fail net-client || true
if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi

# --- Endpoints ---
SERVER_POD_IP="$(kubectl -n "$NS" get pod net-server -o jsonpath='{.status.podIP}' 2>/dev/null || true)"
CLIENT_POD="$(kubectl -n "$NS" get pod net-client -o name | sed 's|pod/||')"
PRIMARY_NODE_IP="$(kubectl get node "$PRIMARY_NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
SVC_IP="$(kubectl -n "$NS" get svc net-svc -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"

client_exec() {
  kubectl -n "$NS" exec "$CLIENT_POD" -- sh -c "$1"
}

# --- 1) Pod → Pod (overlay): HTTP to server pod IP:9100 ---
if client_exec "timeout ${HTTP_TIMEOUT} wget -qO- --timeout=5 http://${SERVER_POD_IP}:9100/echo?msg=ok >/dev/null 2>&1"; then
  if [[ "$SINGLE_NODE" -eq 1 ]]; then
    print_status PASS "Pod → Pod HTTP to ${SERVER_POD_IP}:9100 OK (single-node path)."
  else
    print_status PASS "Pod → Pod HTTP to ${SERVER_POD_IP}:9100 OK (overlay cross-node)."
  fi
else
  if [[ "$SINGLE_NODE" -eq 1 ]]; then
    print_status FAIL "Pod → Pod HTTP to ${SERVER_POD_IP}:9100 FAILED (single-node path)."
  else
    print_status FAIL "Pod → Pod HTTP to ${SERVER_POD_IP}:9100 FAILED (overlay/vxlan/bgp)."
  fi
  FAIL=1
fi

# --- 2) Pod → Service (cluster routing): HTTP to service IP:9100 ---
if client_exec "timeout ${HTTP_TIMEOUT} wget -qO- --timeout=5 http://${SVC_IP}:9100/echo?msg=ok >/dev/null 2>&1"; then
  print_status PASS "Pod → Service HTTP to ${SVC_IP}:9100 OK (cluster service routing)."
else
  print_status FAIL "Pod → Service HTTP to ${SVC_IP}:9100 FAILED (kube-proxy/CNI path)."
  FAIL=1
fi

# --- 3) Pod → Node (hostNetwork): HTTP to primary node IP:9100 ---
if client_exec "timeout ${HTTP_TIMEOUT} wget -qO- --timeout=5 http://${PRIMARY_NODE_IP}:9100/echo?msg=ok >/dev/null 2>&1"; then
  if [[ "$SINGLE_NODE" -eq 1 ]]; then
    print_status PASS "Pod → Node HTTP to ${PRIMARY_NODE_IP}:9100 OK (single-node/hostNetwork)."
  else
    print_status PASS "Pod → Node HTTP to ${PRIMARY_NODE_IP}:9100 OK (node path/firewall)."
  fi
else
  print_status FAIL "Pod → Node HTTP to ${PRIMARY_NODE_IP}:9100 FAILED (node path/firewall)."
  FAIL=1
fi

# Cleanup
cleanup
print_status INFO "On-prem connectivity probes cleaned up. PRIMARY=${PRIMARY_NODE} SECONDARY=${SECONDARY_NODE}"

if [[ "$FAIL" -eq 0 ]]; then
  exit 0
else
  exit 1
fi

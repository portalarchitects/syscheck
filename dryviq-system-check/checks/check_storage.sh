#!/bin/bash
# Storage readiness: DryvIQ runs Postgres + ClickHouse, which need PersistentVolumes.
# A missing default StorageClass or broken CSI provisioner is a top cause of
# "deploy hangs forever". This actually provisions a small PVC + pod and waits
# for it to Bound/Ready, then cleans up.
set -u
set -o pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

READINESS_TIMEOUT="${PREFLIGHT_READINESS_TIMEOUT:-180s}"
BIND_TIMEOUT_SECS="${PREFLIGHT_PVC_TIMEOUT_SECS:-120}"
CLIENT_IMAGE="${PREFLIGHT_STORAGE_IMAGE:-busybox:1.36}"
NS="$(new_probe_namespace dryviq-preflight-storage)"

FAIL=0
cleanup() { kubectl delete ns "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

# 1) StorageClasses present, and is there a default?
SC_LIST=$(kubectl get sc -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' 2>/dev/null || true)
if [[ -z "$SC_LIST" ]]; then
  print_status FAIL "No StorageClasses found. DryvIQ stateful components (Postgres/ClickHouse) cannot provision volumes."
  exit 1
fi

DEFAULT_SC=""
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  name="${line%%|*}"
  isdef="${line##*|}"
  if [[ "$isdef" == "true" ]]; then
    DEFAULT_SC="$name"
    print_status PASS "Default StorageClass: '$name'"
  else
    print_status INFO "StorageClass available: '$name'"
  fi
done <<< "$SC_LIST"

if [[ -z "$DEFAULT_SC" ]]; then
  print_status WARN "No default StorageClass marked. Charts without an explicit storageClassName will fail to bind unless one is set."
fi

# 2) Live provisioning test (PVC -> Bound -> mounted by a pod)
kubectl create ns "$NS" >/dev/null 2>&1 || true

cat <<YAML | kubectl -n "$NS" apply -f - >/dev/null 2>&1
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: preflight-pvc
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 1Gi
YAML

# Wait for Bound (dynamic provisioners may be WaitForFirstConsumer, so also start a pod)
cat <<YAML | kubectl -n "$NS" apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: preflight-storage
spec:
  containers:
  - name: c
    image: ${CLIENT_IMAGE}
    imagePullPolicy: IfNotPresent
    command: ["sh","-c","echo preflight > /data/test && sync && sleep 3600"]
    volumeMounts:
    - name: vol
      mountPath: /data
    securityContext:
      allowPrivilegeEscalation: false
  volumes:
  - name: vol
    persistentVolumeClaim:
      claimName: preflight-pvc
  restartPolicy: Never
YAML

# Poll PVC phase + pod readiness within the bind timeout.
bound=0
deadline=$(( $(date +%s) + BIND_TIMEOUT_SECS ))
while [[ $(date +%s) -lt $deadline ]]; do
  phase=$(kubectl -n "$NS" get pvc preflight-pvc -o jsonpath='{.status.phase}' 2>/dev/null || true)
  if [[ "$phase" == "Bound" ]]; then bound=1; break; fi
  sleep 5
done

if [[ "$bound" -eq 1 ]]; then
  print_status PASS "PVC bound successfully (provisioner working)."
else
  phase=$(kubectl -n "$NS" get pvc preflight-pvc -o jsonpath='{.status.phase}' 2>/dev/null || echo Unknown)
  print_status FAIL "PVC did not bind within ${BIND_TIMEOUT_SECS}s (phase=$phase)."
  kubectl -n "$NS" describe pvc preflight-pvc 2>/dev/null | grep -iA3 events || true
  print_status INFO "Check the CSI driver / provisioner pods and that a usable StorageClass exists."
  FAIL=1
fi

if [[ "$bound" -eq 1 ]]; then
  if kubectl -n "$NS" wait --for=condition=Ready pod/preflight-storage --timeout="$READINESS_TIMEOUT" >/dev/null 2>&1; then
    print_status PASS "Volume mounted and writable by a pod."
  else
    print_status FAIL "Pod could not mount the volume within ${READINESS_TIMEOUT}."
    kubectl -n "$NS" describe pod preflight-storage 2>/dev/null | grep -iA3 events || true
    FAIL=1
  fi
fi

cleanup
trap - EXIT

if [[ "$FAIL" -eq 0 ]]; then
  print_status PASS "Storage provisioning is functional."
  exit 0
else
  print_status FAIL "Storage provisioning has problems (see above)."
  exit 1
fi

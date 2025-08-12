#!/bin/bash
set -euo pipefail

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

# What namespace should we assume for app workloads?
TARGET_NS="${TARGET_NAMESPACE:-default}"

FAIL=0

# 1) Pod Security Standards labels on namespaces (PSA)
#    We scan all namespaces and report enforce levels.
PSA_NS_OUTPUT=$(kubectl get ns -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.labels.pod-security\.kubernetes\.io/enforce}{"|"}{.metadata.labels.pod-security\.kubernetes\.io/enforce-version}{"\n"}{end}' 2>/dev/null || true)

if [[ -z "$PSA_NS_OUTPUT" ]]; then
  print_status WARN "Could not read namespace labels for Pod Security (no output)."
else
  # Summarize any enforced levels, highlight restricted
  while IFS= read -r line; do
    ns=$(echo "$line" | awk -F'|' '{print $1}')
    lvl=$(echo "$line" | awk -F'|' '{print $2}')
    ver=$(echo "$line" | awk -F'|' '{print $3}')
    [[ -z "$ns" ]] && continue
    if [[ -n "$lvl" ]]; then
      if [[ "$lvl" == "restricted" ]]; then
        print_status WARN "Namespace '$ns' enforces Pod Security: level=restricted ${ver:+(version $ver)}"
      else
        print_status INFO "Namespace '$ns' enforces Pod Security: level=$lvl ${ver:+(version $ver)}"
      fi
    fi
  done <<< "$PSA_NS_OUTPUT"
fi

# 2) Gatekeeper (OPA) constraints, if present
#    Detect CRDs and list any enforced constraints
if kubectl api-resources --api-group=constraints.gatekeeper.sh >/dev/null 2>&1; then
  # Show how many constraints exist and list kinds
  GK_SUMMARY=$(kubectl api-resources --api-group=constraints.gatekeeper.sh -o name 2>/dev/null | tr '\n' ' ')
  if [[ -n "$GK_SUMMARY" ]]; then
    print_status INFO "Gatekeeper constraints API detected: $GK_SUMMARY"
    # For each constraint kind, list instances
    while read -r kind; do
      [[ -z "$kind" ]] && continue
      # Extract short kind (before the dot)
      short=$(echo "$kind" | awk -F'.' '{print $1}')
      # List constraint names
      names=$(kubectl get "$short.constraints.gatekeeper.sh" -A --no-headers 2>/dev/null | awk '{print $1 "/" $2}')
      if [[ -n "$names" ]]; then
        while read -r nm; do
          [[ -z "$nm" ]] && continue
          print_status WARN "Gatekeeper constraint present: $short $nm"
        done <<< "$names"
      fi
    done <<< "$(kubectl api-resources --api-group=constraints.gatekeeper.sh -o name 2>/dev/null)"
  else
    print_status INFO "Gatekeeper CRDs present, but no constraints found."
  fi
else
  print_status INFO "Gatekeeper constraints API not detected."
fi

# 3) Kyverno (optional) — if installed, show policies
if kubectl api-resources | grep -qE '^policies.kyverno.io'; then
  KYV_POL=$(kubectl get cpol -A --no-headers 2>/dev/null || true)
  if [[ -n "$KYV_POL" ]]; then
    while read -r row; do
      [[ -z "$row" ]] && continue
      ns=$(echo "$row" | awk '{print $1}')
      name=$(echo "$row" | awk '{print $2}')
      print_status WARN "Kyverno ClusterPolicy present: ${ns}/${name}"
    done <<< "$KYV_POL"
  else
    print_status INFO "Kyverno API detected, but no ClusterPolicies found."
  fi
else
  print_status INFO "Kyverno not detected."
fi

# 4) Server-side dry-run probes to catch common admission blocks.
#    We do NOT actually create anything. We just ask the API server to validate.
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# Helper to dry-run apply a manifest and report
dryrun_apply() {
  local name="$1"
  local file="$2"
  if out=$(kubectl apply --dry-run=server -f "$file" 2>&1); then
    print_status PASS "Dry-run '$name' accepted by admission."
  else
    print_status FAIL "Dry-run '$name' rejected: $out"
    FAIL=1
  fi
}

# Make sure target namespace exists (we won't create it)
if ! kubectl get ns "$TARGET_NS" >/dev/null 2>&1; then
  print_status WARN "Target namespace '$TARGET_NS' does not exist (dry-run tests validate cluster-level policies only)."
fi

# Test 4a: Privileged pod (commonly blocked by restricted policies)
cat > "$tmpdir/privileged.yaml" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: preflight-privileged-probe
  namespace: default
spec:
  containers:
  - name: c
    image: busybox
    command: ["sh","-c","sleep 1"]
    securityContext:
      privileged: true
  restartPolicy: Never
YAML
# Swap namespace if TARGET_NS set
sed -i "s/namespace: default/namespace: ${TARGET_NS}/" "$tmpdir/privileged.yaml"
dryrun_apply "privileged-pod" "$tmpdir/privileged.yaml"

# Test 4b: hostPath mount (often blocked)
cat > "$tmpdir/hostpath.yaml" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: preflight-hostpath-probe
  namespace: default
spec:
  containers:
  - name: c
    image: busybox
    command: ["sh","-c","sleep 1"]
    volumeMounts:
    - name: hp
      mountPath: /host
  volumes:
  - name: hp
    hostPath:
      path: /var/log
      type: Directory
  restartPolicy: Never
YAML
sed -i "s/namespace: default/namespace: ${TARGET_NS}/" "$tmpdir/hostpath.yaml"
dryrun_apply "hostpath-pod" "$tmpdir/hostpath.yaml"

# Test 4c: runAsNonRoot=false (root) — restricted often requires non-root
cat > "$tmpdir/rootuser.yaml" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: preflight-rootuser-probe
  namespace: default
spec:
  securityContext:
    runAsNonRoot: false
  containers:
  - name: c
    image: busybox
    command: ["sh","-c","sleep 1"]
  restartPolicy: Never
YAML
sed -i "s/namespace: default/namespace: ${TARGET_NS}/" "$tmpdir/rootuser.yaml"
dryrun_apply "rootuser-pod" "$tmpdir/rootuser.yaml"

# Test 4d: hostNetwork true (often allowed, but sometimes blocked)
cat > "$tmpdir/hostnet.yaml" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: preflight-hostnet-probe
  namespace: default
spec:
  hostNetwork: true
  containers:
  - name: c
    image: busybox
    command: ["sh","-c","sleep 1"]
  restartPolicy: Never
YAML
sed -i "s/namespace: default/namespace: ${TARGET_NS}/" "$tmpdir/hostnet.yaml"
dryrun_apply "hostnetwork-pod" "$tmpdir/hostnet.yaml"

# Final note
print_status INFO "This check reports likely admission/PSA policy rejections via dry-run. Adjust TARGET_NAMESPACE env if needed (current: '${TARGET_NS}')."

if [[ "$FAIL" -eq 0 ]]; then
  :
else
  exit 1
fi

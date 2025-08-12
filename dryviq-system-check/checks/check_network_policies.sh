#!/bin/bash
# Audits Kubernetes NetworkPolicies for default-deny patterns and (if present) Calico global policies.
# No jq/yq required.

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

# If cluster has no NetworkPolicy resource at all (ancient or weird distros)
if ! kubectl api-resources | awk '{print $1}' | grep -qx "networkpolicies"; then
  print_status SKIP "NetworkPolicy API not available on this cluster."
  exit 0
fi

FAIL=0
WARNED=0

# 1) Quick per-namespace counts (helps spot locked-down namespaces)
COUNTS=$(kubectl get netpol -A --no-headers 2>/dev/null | awk '{count[$1]++} END {for (ns in count) printf "%s\t%d\n", ns, count[ns]}' | sort)
if [[ -n "$COUNTS" ]]; then
  print_status INFO "NetworkPolicies present (namespace → count):"
  echo "$COUNTS" | awk '{printf "  • %s: %s\n", $1, $2}'
else
  print_status INFO "No NetworkPolicies found in any namespace."
fi

# 2) Detect default-deny patterns:
#    - Ingress default deny:  podSelector empty AND policyTypes has Ingress AND ingress rules empty
#    - Egress default deny:   podSelector empty AND policyTypes has Egress  AND egress rules empty
# We iterate policies (namespace/name) and inspect fields with jsonpath, no jq.

nl=$'\n'
POL_LIST=$(kubectl get netpol -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name --no-headers 2>/dev/null || true)
DDI=()  # default deny ingress (ns/name)
DDE=()  # default deny egress (ns/name)

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  ns=$(echo "$line" | awk '{print $1}')
  name=$(echo "$line" | awk '{print $2}')

  # podSelector empty? (jsonpath often prints 'map[]' for empty)
  podsel=$(kubectl -n "$ns" get netpol "$name" -o jsonpath='{.spec.podSelector}' 2>/dev/null || true)
  [[ -z "$podsel" ]] && podsel="{}"
  is_empty_selector=0
  if [[ "$podsel" == "map[]" || "$podsel" == "{}" ]]; then
    is_empty_selector=1
  fi

  # policyTypes
  ptypes=$(kubectl -n "$ns" get netpol "$name" -o jsonpath='{.spec.policyTypes[*]}' 2>/dev/null || true)
  has_ingress=0; has_egress=0
  [[ "$ptypes" =~ Ingress ]] && has_ingress=1
  [[ "$ptypes" =~ Egress ]] && has_egress=1

  # ingress rules empty?
  ingr=$(kubectl -n "$ns" get netpol "$name" -o jsonpath='{.spec.ingress}' 2>/dev/null || true)
  # egress rules empty?
  egr=$(kubectl -n "$ns" get netpol "$name" -o jsonpath='{.spec.egress}' 2>/dev/null || true)

  empty_ingress=0; empty_egress=0
  [[ -z "$ingr" || "$ingr" == "[]" ]] && empty_ingress=1
  [[ -z "$egr"  || "$egr"  == "[]" ]] && empty_egress=1

  # Record default-deny hits
  if [[ $is_empty_selector -eq 1 && $has_ingress -eq 1 && $empty_ingress -eq 1 ]]; then
    DDI+=("${ns}/${name}")
  fi
  if [[ $is_empty_selector -eq 1 && $has_egress -eq 1 && $empty_egress -eq 1 ]]; then
    DDE+=("${ns}/${name}")
  fi
done <<< "$POL_LIST"

if [[ ${#DDI[@]} -gt 0 ]]; then
  print_status WARN "Default-deny Ingress policies detected (apply to all pods in namespace):"
  for item in "${DDI[@]}"; do
    echo "  • $item"
  done
  WARNED=1
fi

if [[ ${#DDE[@]} -gt 0 ]]; then
  print_status WARN "Default-deny Egress policies detected (apply to all pods in namespace):"
  for item in "${DDE[@]}"; do
    echo "  • $item"
  done
  WARNED=1
fi

# 3) Calico global policies (if Calico CRDs exist)
if kubectl get crd 2>/dev/null | grep -q '^globalnetworkpolicies.crd.projectcalico.org'; then
  GNP=$(kubectl get globalnetworkpolicies.crd.projectcalico.org -o name 2>/dev/null || true)
  if [[ -n "$GNP" ]]; then
    print_status WARN "Calico GlobalNetworkPolicies present (cluster-wide); verify they allow required traffic:"
    echo "$GNP" | sed 's/^/  • /'
    WARNED=1
  fi
fi
if kubectl get crd 2>/dev/null | grep -q '^globalnetworksets.crd.projectcalico.org'; then
  GNS=$(kubectl get globalnetworksets.crd.projectcalico.org -o name 2>/dev/null || true)
  if [[ -n "$GNS" ]]; then
    print_status INFO "Calico GlobalNetworkSets present:"
    echo "$GNS" | sed 's/^/  • /'
  fi
fi

# Outcome
if [[ $WARNED -eq 0 ]]; then
  print_status PASS "No namespace-wide default-deny NetworkPolicies detected."
  exit 0
else
  print_status WARN "Review the NetworkPolicies above; ensure namespaces used for DryvIQ have explicit allow rules."
  exit 0
fi

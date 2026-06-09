#!/bin/bash
# Node health & capacity. Instance *type* being correct doesn't mean nodes are
# schedulable: pressure conditions, NotReady nodes, and restrictive
# ResourceQuotas/LimitRanges all silently block DryvIQ workloads.
set -u
set -o pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

TARGET_NS="${TARGET_NAMESPACE:-default}"
FAIL=0

# 1) Node Ready + pressure conditions
NODES=$(kubectl get nodes -o name 2>/dev/null | sed 's|node/||')
if [[ -z "$NODES" ]]; then
  print_status FAIL "No nodes returned by the API server (cluster unreachable?)."
  exit 1
fi

node_count=0
not_ready=0
for n in $NODES; do
  ((node_count++))
  conds=$(kubectl get node "$n" -o jsonpath='{range .status.conditions[*]}{.type}={.status};{end}' 2>/dev/null)
  ready=$(echo "$conds" | tr ';' '\n' | grep '^Ready=' | cut -d= -f2)
  if [[ "$ready" != "True" ]]; then
    print_status FAIL "Node '$n' is not Ready (Ready=$ready)."
    not_ready=1
    FAIL=1
  fi
  for p in MemoryPressure DiskPressure PIDPressure; do
    val=$(echo "$conds" | tr ';' '\n' | grep "^$p=" | cut -d= -f2)
    if [[ "$val" == "True" ]]; then
      print_status WARN "Node '$n' reports $p=True."
    fi
  done
done
if [[ "$not_ready" -eq 0 ]]; then
  print_status PASS "All $node_count node(s) are Ready."
fi

# 2) Allocatable totals (informational; charts request real CPU/mem)
total_cpu=0
total_mem_ki=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  cpu="${line%%|*}"
  mem="${line##*|}"
  # cpu may be like "8" or "7900m"
  if [[ "$cpu" == *m ]]; then
    cpu=$(( ${cpu%m} / 1000 ))
  fi
  [[ "$cpu" =~ ^[0-9]+$ ]] && total_cpu=$(( total_cpu + cpu ))
  # mem like "32905848Ki"
  if [[ "$mem" == *Ki ]]; then
    total_mem_ki=$(( total_mem_ki + ${mem%Ki} ))
  fi
done < <(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.cpu}|{.status.allocatable.memory}{"\n"}{end}' 2>/dev/null)
if [[ "$total_cpu" -gt 0 ]]; then
  print_status INFO "Cluster allocatable (approx): ${total_cpu} CPU cores, $(( total_mem_ki / 1024 / 1024 )) GiB RAM across ${node_count} node(s)."
fi

# 3) ResourceQuota / LimitRange in target namespace
if kubectl get ns "$TARGET_NS" >/dev/null 2>&1; then
  RQ=$(kubectl -n "$TARGET_NS" get resourcequota --no-headers 2>/dev/null | awk '{print $1}')
  if [[ -n "$RQ" ]]; then
    print_status WARN "ResourceQuota present in '$TARGET_NS' ($(echo "$RQ" | tr '\n' ' ')); ensure limits accommodate DryvIQ's requests."
  fi
  LR=$(kubectl -n "$TARGET_NS" get limitrange --no-headers 2>/dev/null | awk '{print $1}')
  if [[ -n "$LR" ]]; then
    print_status WARN "LimitRange present in '$TARGET_NS' ($(echo "$LR" | tr '\n' ' ')); defaults may clash with chart resource specs."
  fi
fi

if [[ "$FAIL" -eq 0 ]]; then
  print_status PASS "Node health looks good."
  exit 0
else
  print_status FAIL "Node health/capacity issues detected (see above)."
  exit 1
fi

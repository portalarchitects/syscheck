#!/bin/bash

print_status() {
  local status="$1"
  shift
  case "$status" in
    PASS) color='\033[0;32m' ;;
    WARN) color='\033[1;33m' ;;
    FAIL) color='\033[0;31m' ;;
    SKIP) color='\033[0;34m' ;;
    *)    color='\033[0m' ;;
  esac
  echo -e "${color}[$status]\033[0m $*"
}

FAIL=0

if [[ "$ENVIRONMENT" == "aks" ]]; then
    POOLS=(migration discover dryviqpool clickhouse proxy)
    for pool in "${POOLS[@]}"; do
        pool_info=$(az aks nodepool show --resource-group "$RESOURCE_GROUP" --cluster-name "$CLUSTER_NAME" --name "$pool" 2>/dev/null)
        if [[ -z "$pool_info" ]]; then
            print_status FAIL "Nodepool '$pool' not found in cluster."
            FAIL=1
            continue
        fi

        # Pool node count
        nodes=$(kubectl get nodes -l "agentpool=$pool" --no-headers 2>/dev/null | wc -l)
        [[ "$nodes" == "0" ]] && nodes=$(kubectl get nodes -l "pool=$pool" --no-headers 2>/dev/null | wc -l)
        [[ "$nodes" == "0" ]] && nodes=$(kubectl get nodes | grep "$pool" | wc -l)

        if [[ "$nodes" == "0" ]]; then
            print_status WARN "No nodes found in pool '$pool'"
            # Checking taints for nodepools with no nodes
            taints=$(echo "$pool_info" | grep -o 'dedicated=[^,"]*:NoExecute')
            if echo "$taints" | grep -q "dedicated=$pool:NoExecute"; then
                print_status PASS "Nodepool '$pool' (no nodes running) is configured with taint 'dedicated=$pool:NoExecute'"
            else
                print_status FAIL "Nodepool '$pool' (no nodes running) does NOT have taint 'dedicated=$pool:NoExecute'"
                FAIL=1
            fi
        else
            print_status PASS "Found $nodes node(s) in pool '$pool'"
            # Checking taints for nodepools with active nodes
            taint_found=0
            node_names=$(kubectl get nodes -l "agentpool=$pool" -o name 2>/dev/null)
            if [[ -z "$node_names" ]]; then
                node_names=$(kubectl get nodes -l "pool=$pool" -o name 2>/dev/null)
            fi
            if [[ -z "$node_names" ]]; then
                node_names=$(kubectl get nodes | grep "$pool" | awk '{print $1}')
            fi
            for node in $node_names; do
                if kubectl describe "$node" | grep -q "dedicated=$pool:NoExecute"; then
                    taint_found=1
                    break
                fi
            done
            if [[ "$taint_found" == "1" ]]; then
                print_status PASS "Found taint 'dedicated=$pool:NoExecute' on a node in pool '$pool'"
            else
                print_status FAIL "Taint 'dedicated=$pool:NoExecute' NOT found on any node in pool '$pool'"
                FAIL=1
            fi
        fi
    done

elif [[ "$ENVIRONMENT" == "k3s" ]]; then
    REQUIRED_NODES=(dryviq clickhouse postgres logging worker1)
    for name in "${REQUIRED_NODES[@]}"; do
        if ! kubectl get nodes | grep -qw "$name"; then
            print_status FAIL "Node named '$name' not found"
            FAIL=1
        else
            print_status PASS "Node named '$name' found"
        fi
    done
    WORKERS=$(kubectl get nodes | grep -E '^worker[0-9]+' | wc -l)
    if [[ "$WORKERS" -ge 1 ]]; then
        print_status PASS "Found $WORKERS workerN node(s)"
    else
        print_status FAIL "No workerN nodes found"
        FAIL=1
    fi
fi

if [[ "$FAIL" == "0" ]]; then
    print_status PASS "All required node pools/names/taints present."
else
    print_status FAIL "Issues found in node pools/names/taints."
fi

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

if [[ "$ENVIRONMENT" == "k3s" ]]; then
  echo -e "\033[1;33m"
  echo "=============================================================="
  echo "     IMPORTANT: Minimum Hardware Requirements for K3s Nodes   "
  echo "--------------------------------------------------------------"
  echo "   master   : 8 cores, 16GB RAM, 512GB+ disk"
  echo "   pg       : 8 cores, 32GB RAM, 1TB+ disk"
  echo "   ch       : 8 cores, 32GB RAM, 1TB+ disk"
  echo "   logging  : 4 cores, 16GB RAM, 512GB+ disk"
  echo "   workerN  : 8 cores, 32GB RAM, 128GB+ disk"
  echo "--------------------------------------------------------------"
  echo " NOTE: Disk, RAM, and CPU specs CANNOT be reliably checked by"
  echo " this script for on-prem nodes. Please verify manually before"
  echo " proceeding with installation!"
  echo "=============================================================="
  echo -e "\033[0m"
  print_status WARN "K3s node hardware requirements are not auto-validated. Please check the above specs manually."
  exit 0
fi

FAIL=0

if [[ "$ENVIRONMENT" == "aks" ]]; then
  declare -A ALLOWED_AKS_INSTANCES

  # 4c/8GB (low-mem) or 4c/16GB, all amd64
  ALLOWED_AKS_INSTANCES[dryviq]="\
    Standard_D4s_V3 Standard_D4s_V4 Standard_D4s_V5 \
    Standard_D4as_V5 \
    Standard_D4ads_V5 Standard_D4ads_V6 \
    Standard_D4ls_V5 Standard_D4als_V6 \
    Standard_F4s_V2"

  # Same as dryviq
  ALLOWED_AKS_INSTANCES[migration]="\
    Standard_D4s_V3 Standard_D4s_V4 Standard_D4s_V5 \
    Standard_D4as_V5 \
    Standard_D4ads_V5 Standard_D4ads_V6 \
    Standard_D4ls_V5 Standard_D4als_V6 \
    Standard_F4s_V2"

  # 8c/16GB (low-mem) or 8c/32GB, all amd64
  ALLOWED_AKS_INSTANCES[discover]="\
    Standard_D8s_V3 Standard_D8s_V4 Standard_D8s_V5 \
    Standard_D8as_V5 \
    Standard_D8ads_V5 Standard_D8ads_V6 \
    Standard_D8ls_V5 Standard_D8als_V6 \
    Standard_F8s_V2"

  # 2c/4GB, all amd64
  ALLOWED_AKS_INSTANCES[proxy]="\
    Standard_D2als_V6 Standard_D2ls_V5 \
    Standard_F2s_V2 \
    Standard_D2s_V3 \
    Standard_B2s_V2 Standard_B2ls_V2"

  # ClickHouse: 4c/16GB, 4c/32GB, 8c/32GB on amd64 or arm64
  # amd64
  #   4/16: D4s*
  #   4/32: E4s*/E4ps*
  #   8/32: D8s*
  # arm64 (Ampere): D*ps_V5 for 4/16 & 8/32, E4ps_V5 for 4/32
  ALLOWED_AKS_INSTANCES[clickhouse]="\
    Standard_D4s_V3 Standard_D4s_V4 Standard_D4s_V5 \
    Standard_D8s_V3 Standard_D8s_V4 Standard_D8s_V5 \
    Standard_E4s_V5 Standard_E4ps_V5 \
    Standard_D4ps_V5 Standard_D8ps_V5 \
    Standard_E8s_V5 Standard_E8ps_V5"
fi


  for POOL in dryviq migration discover proxy clickhouse; do
    pool_info=$(az aks nodepool show --resource-group "$RESOURCE_GROUP" --cluster-name "$CLUSTER_NAME" --name "$POOL" 2>/dev/null)
    if [[ -z "$pool_info" ]]; then
      print_status WARN "Nodepool '$POOL' not found, skipping instance type check."
      continue
    fi
    vm_size=$(echo "$pool_info" | grep -o '"vmSize": *"[^"]*"' | head -1 | awk -F'"' '{print $4}')
    vm_size_norm=$(echo "$vm_size" | sed -E 's/^standard/Standard/' | sed -E 's/_([a-z])/_\U\1/g')
    allowed_instances="${ALLOWED_AKS_INSTANCES[$POOL]}"
    match=0
    for inst in $allowed_instances; do
      if [[ "$vm_size_norm" == "$inst" ]]; then
        match=1
        break
      fi
    done
    if [[ "$match" == 1 ]]; then
      print_status PASS "Nodepool '$POOL': Instance type $vm_size_norm is allowed."
    else
      print_status FAIL "Nodepool '$POOL': Instance type $vm_size_norm is NOT in allowed list: $allowed_instances"
      FAIL=1
    fi
  done

if [[ "$ENVIRONMENT" == "eks" ]]; then
  declare -A ALLOWED_EKS_INSTANCES
  ALLOWED_EKS_INSTANCES[dryviq]="m5.xlarge m5a.xlarge"
  ALLOWED_EKS_INSTANCES[migration]="m5.xlarge m5a.xlarge"
  ALLOWED_EKS_INSTANCES[discover]="m5.2xlarge"
  ALLOWED_EKS_INSTANCES[proxy]="t3.micro t3.small"
  ALLOWED_EKS_INSTANCES[clickhouse]="r5.2xlarge r5.4xlarge"

  for POOL in dryviq migration discover proxy clickhouse; do
    group_info=$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$POOL" 2>/dev/null)
    if [[ -z "$group_info" ]]; then
      print_status WARN "Nodegroup '$POOL' not found, skipping instance type check."
      continue
    fi
    instance_type=$(echo "$group_info" | grep -o '"instanceTypes": *\[[^]]*\]' | head -1 | grep -o '"[a-zA-Z0-9._-]*"' | head -1 | tr -d '"')
    allowed_instances="${ALLOWED_EKS_INSTANCES[$POOL]}"
    match=0
    for inst in $allowed_instances; do
      if [[ "$instance_type" == "$inst" ]]; then
        match=1
        break
      fi
    done
    if [[ "$match" == 1 ]]; then
      print_status PASS "Nodegroup '$POOL': Instance type $instance_type is allowed."
    else
      print_status FAIL "Nodegroup '$POOL': Instance type $instance_type is NOT in allowed list: $allowed_instances"
      FAIL=1
    fi
  done
fi

if [[ "$ENVIRONMENT" == "k3s" ]]; then
  exit 0
elif [[ "$FAIL" == "0" ]]; then
  print_status PASS "All nodes/nodepools meet minimum machine requirements."
else
  print_status FAIL "Some nodes/nodepools do not meet minimum machine requirements."
fi

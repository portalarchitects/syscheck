#!/bin/bash
# Cloud control-plane / VPC network config that the in-cluster probes can't see:
#   AKS: outbound type (UDR masks egress problems), private API server.
#   EKS: subnet free-IP count (VPC-CNI IP exhaustion), VPC endpoints for private
#        clusters, API endpoint access.
set -u
set -o pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

FAIL=0

# Minimum free IPs per subnet before we warn about exhaustion.
MIN_FREE_IPS="${PREFLIGHT_MIN_FREE_IPS:-16}"

if [[ "${ENVIRONMENT:-}" == "aks" ]]; then
  if ! command -v az &>/dev/null; then
    print_status SKIP "az CLI not available; skipping AKS network config check."
    exit 0
  fi
  AKS_JSON_QUERY="networkProfile.outboundType"
  outbound=$(az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --query "$AKS_JSON_QUERY" -o tsv 2>/dev/null)
  if [[ -z "$outbound" ]]; then
    print_status WARN "Could not read AKS network profile (check RESOURCE_GROUP/CLUSTER_NAME and az login)."
  else
    case "$outbound" in
      loadBalancer)
        print_status PASS "AKS outbound type: loadBalancer (managed egress)." ;;
      userDefinedRouting)
        print_status WARN "AKS outbound type: userDefinedRouting. Egress goes through YOUR firewall/NVA — the in-cluster reachability test only passes if that firewall allows the required DryvIQ/registry endpoints."
        ;;
      *NATGateway|managedNATGateway|userAssignedNATGateway)
        print_status PASS "AKS outbound type: $outbound (NAT gateway egress)." ;;
      *)
        print_status INFO "AKS outbound type: $outbound." ;;
    esac
  fi

  private=$(az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --query "apiServerAccessProfile.enablePrivateCluster" -o tsv 2>/dev/null)
  if [[ "$private" == "true" ]]; then
    print_status WARN "AKS API server is PRIVATE. Ensure this tool runs from a host with network line-of-sight to the private API endpoint (VNet/peering/VPN)."
  fi

  # Managed outbound IP count (SNAT capacity hint)
  ipcount=$(az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --query "networkProfile.loadBalancerProfile.managedOutboundIPs.count" -o tsv 2>/dev/null)
  if [[ -n "$ipcount" && "$ipcount" != "None" ]]; then
    print_status INFO "AKS managed outbound IPs: ${ipcount} (each adds ~64k SNAT ports; scale up if egress-heavy)."
  fi

elif [[ "${ENVIRONMENT:-}" == "eks" ]]; then
  if ! command -v aws &>/dev/null; then
    print_status SKIP "aws CLI not available; skipping EKS network config check."
    exit 0
  fi

  # API endpoint access
  read -r pub priv < <(aws eks describe-cluster --name "$CLUSTER_NAME" \
      --query "cluster.resourcesVpcConfig.[endpointPublicAccess,endpointPrivateAccess]" \
      --output text 2>/dev/null)
  if [[ -n "$pub$priv" ]]; then
    print_status INFO "EKS API access: publicAccess=$pub privateAccess=$priv."
    if [[ "$pub" == "False" && "$priv" == "True" ]]; then
      print_status WARN "EKS API is private-only. Run this tool from inside the VPC (or via peering/VPN) and ensure VPC endpoints exist for ECR/S3/STS."
    fi
  else
    print_status WARN "Could not read EKS cluster config (check CLUSTER_NAME and aws credentials/region)."
  fi

  # Subnet free IPs (VPC-CNI assigns pod IPs from these subnets)
  SUBNETS=$(aws eks describe-cluster --name "$CLUSTER_NAME" \
      --query "cluster.resourcesVpcConfig.subnetIds" --output text 2>/dev/null)
  VPC_ID=""
  if [[ -n "$SUBNETS" ]]; then
    for s in $SUBNETS; do
      read -r free vpc < <(aws ec2 describe-subnets --subnet-ids "$s" \
          --query "Subnets[0].[AvailableIpAddressCount,VpcId]" --output text 2>/dev/null)
      VPC_ID="$vpc"
      if [[ -n "$free" && "$free" =~ ^[0-9]+$ ]]; then
        if [[ "$free" -lt "$MIN_FREE_IPS" ]]; then
          print_status FAIL "Subnet $s has only $free free IPs (< $MIN_FREE_IPS). VPC-CNI will fail to assign pod IPs — pods stuck Pending."
          FAIL=1
        else
          print_status PASS "Subnet $s has $free free IPs."
        fi
      fi
    done
  fi

  # VPC endpoints (matter for private clusters / no NAT)
  if [[ -n "$VPC_ID" ]]; then
    EPS=$(aws ec2 describe-vpc-endpoints \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query "VpcEndpoints[].ServiceName" --output text 2>/dev/null | tr '\t' '\n')
    if [[ -n "$EPS" ]]; then
      for need in ecr.api ecr.dkr s3 sts; do
        if echo "$EPS" | grep -q "\.${need}$\|\.${need}\b"; then
          print_status PASS "VPC endpoint present for $need."
        else
          print_status INFO "No VPC endpoint for $need (only needed if nodes lack NAT/public egress)."
        fi
      done
    else
      print_status INFO "No VPC endpoints found; fine if nodes have NAT/public egress, required if fully private."
    fi
  fi

else
  print_status SKIP "Cloud network config check runs only for AKS/EKS."
  exit 0
fi

if [[ "$FAIL" -eq 0 ]]; then
  exit 0
else
  exit 1
fi

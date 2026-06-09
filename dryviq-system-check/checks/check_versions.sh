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

KUBECTL_MIN="1.29"
HELM_MIN="3.0"

# kubectl
if ! command -v kubectl &>/dev/null; then
    print_status FAIL "kubectl not installed"
    FAIL=1
else
    ver=$(kubectl version --client --output=yaml 2>/dev/null | grep gitVersion | head -1 | awk '{print $2}' | sed 's/v//')
    if [[ -z "$ver" ]]; then
        print_status FAIL "Unable to determine kubectl version"
        FAIL=1
    elif [[ "$(printf '%s\n' "$KUBECTL_MIN" "$ver" | sort -V | head -n1)" != "$KUBECTL_MIN" ]]; then
        print_status FAIL "kubectl version $ver < $KUBECTL_MIN"
        FAIL=1
    else
        print_status PASS "kubectl version $ver"
    fi
fi

# helm
if ! command -v helm &>/dev/null; then
    print_status FAIL "helm not installed"
    FAIL=1
else
    ver=$(helm version --short | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    if [[ -z "$ver" ]]; then
        print_status FAIL "Unable to determine helm version"
        FAIL=1
    elif [[ "$(printf '%s\n' "$HELM_MIN" "$ver" | sort -V | head -n1)" != "$HELM_MIN" ]]; then
        print_status FAIL "helm version $ver < $HELM_MIN"
        FAIL=1
    else
        print_status PASS "helm version $ver"
    fi
fi

# Cluster server version (skew vs client matters for some APIs)
srv=$(kubectl version --output=yaml 2>/dev/null | grep -A6 serverVersion | grep gitVersion | head -1 | awk '{print $2}' | sed 's/v//')
if [[ -n "$srv" ]]; then
    if [[ "$(printf '%s\n' "$KUBECTL_MIN" "$srv" | sort -V | head -n1)" != "$KUBECTL_MIN" ]]; then
        print_status WARN "Kubernetes server version $srv < $KUBECTL_MIN (recommended minimum)"
    else
        print_status PASS "Kubernetes server version $srv"
    fi
else
    print_status WARN "Unable to determine Kubernetes server version (cluster unreachable?)"
fi

# Cloud CLI presence/version, per environment
if [[ "$ENVIRONMENT" == "aks" ]]; then
    if command -v az &>/dev/null; then
        az_ver=$(az version --output tsv 2>/dev/null | awk '{print $1}' | head -1)
        print_status PASS "az CLI present (${az_ver:-version unknown})"
    else
        print_status FAIL "az CLI not installed (required for AKS checks)"
        FAIL=1
    fi
elif [[ "$ENVIRONMENT" == "eks" ]]; then
    if command -v aws &>/dev/null; then
        aws_ver=$(aws --version 2>&1 | grep -oE 'aws-cli/[0-9.]+' | head -1)
        print_status PASS "aws CLI present (${aws_ver:-version unknown})"
    else
        print_status FAIL "aws CLI not installed (required for EKS checks)"
        FAIL=1
    fi
fi

if [[ "$FAIL" == "0" ]]; then
    print_status PASS "All required tool versions present."
else
    print_status FAIL "One or more required tools missing or too old."
fi

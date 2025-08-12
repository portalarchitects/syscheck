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

if [[ "$FAIL" == "0" ]]; then
    print_status PASS "All required tool versions present."
else
    print_status FAIL "One or more required tools missing or too old."
fi

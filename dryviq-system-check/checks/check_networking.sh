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

ENDPOINTS=(
    # StackGres/Postgres
    "stackgres.io"

    # DryvIQ core platform
    "skysync.azurecr.io"
    "api.portalarchitects.com"
    "skysyncblob.blob.core.windows.net"

    # K3s and dependencies
    "get.k3s.io"
    "rpm.rancher.io"
    "update.k3s.io"

    # Tools/utilities
    "webinstall.dev/k9s"

)

FAIL=0

if [[ "$ENVIRONMENT" == "aks" || "$ENVIRONMENT" == "eks" ]]; then
    POD_NAME="net-check"
    NAMESPACE="default"

    kubectl run "$POD_NAME" --image=curlimages/curl:8.15.0 --restart=Never -n "$NAMESPACE" -- sleep 120 >/dev/null 2>&1
    kubectl wait --for=condition=Ready pod/"$POD_NAME" -n "$NAMESPACE" --timeout=30s >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        print_status FAIL "Diagnostic pod $POD_NAME did not start correctly in namespace $NAMESPACE."
        kubectl delete pod "$POD_NAME" -n "$NAMESPACE" >/dev/null 2>&1
        exit 1
    fi

    for endpoint in "${ENDPOINTS[@]}"; do
        kubectl exec -n "$NAMESPACE" "$POD_NAME" -- curl -sS --max-time 7 -o /dev/null --head "https://$endpoint"
        if [[ $? -eq 0 ]]; then
            print_status PASS "Able to connect to https://$endpoint (in-cluster)"
        else
            print_status FAIL "Cannot connect to https://$endpoint (in-cluster)"
            FAIL=1
        fi
    done

    kubectl delete pod "$POD_NAME" -n "$NAMESPACE" >/dev/null 2>&1
else
    for endpoint in "${ENDPOINTS[@]}"; do
        curl -sS --max-time 7 -o /dev/null --head "https://$endpoint"
        if [[ $? -eq 0 ]]; then
            print_status PASS "Able to connect to https://$endpoint"
        else
            print_status FAIL "Cannot connect to https://$endpoint"
            FAIL=1
        fi
    done
fi

if [[ $FAIL -ne 0 ]]; then
    print_status FAIL "One or more external endpoints were not reachable."
else
    print_status PASS "All external endpoints reachable."
fi

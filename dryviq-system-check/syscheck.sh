#!/bin/bash

# ==== CONFIGURABLES ====
CHECK_LABELS=( "FIREWALL" "MACHINE TYPES" "NETWORKING" "ON-PREM CONNECTIVITY" "NODE LABELS" "TOOL VERSIONS" "ADMISSION CONSTRAINTS" "NETWORK POLICIES" "CLOUD DB CONNECTIVITY" )
CHECK_SCRIPTS=( "check_firewall.sh" "check_instances.sh" "check_networking.sh" "check_onprem_network.sh" "check_node_labels.sh" "check_versions.sh" "check_constraints.sh" "check_network_policies.sh" "check_db_connectivity.sh" )
STEP_ICONS=( 🛡️ 🖥️ 🌐 🔗 🏷️ ⚙️ 🧩 🛡️ 📦 )


SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
CHECKS_DIR="$SCRIPT_DIR/checks"

# ==== COLORS ====
ENDCOLOR='\033[0m'
BLUE_BOLD='\033[1;34m'
RED_BOLD='\033[1;31m'
GREEN_BOLD='\033[1;32m'
YELLOW_BOLD='\033[1;33m'

# ==== UX SETTINGS ====
VERBOSE=0
DEBUG=0

# ==== HANDLE ARGUMENTS ====
for arg in "$@"; do
  case "$arg" in
    -v|--verbose) VERBOSE=1 ;;
    -d|--debug)   DEBUG=1 ;;
    -h|--help)
      echo "Usage: $0 [--verbose] [--debug]"
      exit 0
      ;;
  esac
done

# ==== HEADER ====
print_header() {
  echo -e "${BLUE_BOLD} ____                   ___ ___"
  echo -e "|  _ \\ _ __ _   ___   _|_ _/ _ \\"
  echo -e "| | | | '__| | | \\ \\ / /| | | | |"
  echo -e "| |_| | |  | |_| |\\ V / | | |_| |"
  echo -e "|____/|_|   \\__, | \\_/ |___\\__\\_\\"
  echo -e "            |___/"
  echo -e "╔══════════════════════════════════════════════════════╗"
  echo -e "║           Welcome to the DryvIQ SysCheck!            ║"
  echo -e "╚══════════════════════════════════════════════════════╝${ENDCOLOR}"
}

print_header

# ==== ENVIRONMENT SELECTION ====
echo
echo "Which environment are you checking?"
echo "  1) AKS (Azure Kubernetes Service)"
echo "  2) EKS (Amazon EKS)"
echo "  3) K3s (on-prem)"
read -rp "Enter 1, 2, or 3: " env_num

case "$env_num" in
  1) ENVIRONMENT="aks" ;;
  2) ENVIRONMENT="eks" ;;
  3) ENVIRONMENT="k3s" ;;
  *) echo "Unknown option. Exiting."; exit 1 ;;
esac
export ENVIRONMENT

# ==== KUBECTL CONTEXT ====
echo
CURRENT_CTX=$(kubectl config current-context 2>/dev/null)
echo -e "Current kubectl context: ${BLUE_BOLD}$CURRENT_CTX${ENDCOLOR}"

echo
echo "Available kube contexts:"
kubectl config get-contexts --no-headers | awk '{print NR ") " $2}' | tee /tmp/kube_context_list.txt

echo
read -rp "Use current context [$CURRENT_CTX]? (y/n): " use_current
if [[ "$use_current" =~ ^[Nn]$ ]]; then
  echo
  read -rp "Enter number of context to use: " ctx_num
  NEW_CTX=$(awk -v n="$ctx_num" 'NR==n{print $2}' /tmp/kube_context_list.txt)
  if [[ -n "$NEW_CTX" ]]; then
    kubectl config use-context "$NEW_CTX" >/dev/null
    echo -e "Switched to context: ${BLUE_BOLD}$NEW_CTX${ENDCOLOR}"
  else
    echo -e "${RED_BOLD}Invalid selection. Exiting.${ENDCOLOR}"
    rm -f /tmp/kube_context_list.txt
    exit 1
  fi
else
  echo -e "Using current context: ${BLUE_BOLD}$CURRENT_CTX${ENDCOLOR}"
fi
rm -f /tmp/kube_context_list.txt

# ==== CLOUD ENVIRONMENT PROMPTS ====
normalize_db_endpoints() {
  # Accept space/comma-separated host[:port] tokens; default port 5432
  local raw="$1"
  local arr=()
  # shellcheck disable=SC2206
  local tokens=(${raw//,/ })
  for t in "${tokens[@]}"; do
    t="${t//[[:space:]]/}"
    [[ -z "$t" ]] && continue
    if [[ "$t" == *:* ]]; then
      arr+=("$t")
    else
      arr+=("${t}:5432")
    fi
  done
  printf "%s" "${arr[*]}"
}

if [[ "$ENVIRONMENT" == "aks" ]]; then
  echo
  read -rp "Enter your AKS Resource Group: " RESOURCE_GROUP
  read -rp "Enter your AKS Cluster Name: " CLUSTER_NAME
  export RESOURCE_GROUP
  export CLUSTER_NAME

  echo
  read -rp "Optional: Enter Postgres endpoints (host[:port], space/comma separated) for in-cluster reachability test: " DB_INPUT
  if [[ -n "$DB_INPUT" ]]; then
    DB_ENDPOINTS="$(normalize_db_endpoints "$DB_INPUT")"
    export DB_ENDPOINTS
  fi

elif [[ "$ENVIRONMENT" == "eks" ]]; then
  echo
  read -rp "Enter your EKS Cluster Name: " CLUSTER_NAME
  export CLUSTER_NAME

  echo
  read -rp "Optional: Enter Postgres/Aurora endpoints (host[:port], space/comma separated) for in-cluster reachability test: " DB_INPUT
  if [[ -n "$DB_INPUT" ]]; then
    DB_ENDPOINTS="$(normalize_db_endpoints "$DB_INPUT")"
    export DB_ENDPOINTS
  fi
fi

# ==== MAIN CHECKS LOOP ====
declare -a SUMMARY
TOTAL_STEPS=${#CHECK_SCRIPTS[@]}
CURRENT_STEP=1

for idx in "${!CHECK_SCRIPTS[@]}"; do
  check_script="${CHECK_SCRIPTS[$idx]}"
  section="${CHECK_LABELS[$idx]}"
  icon="${STEP_ICONS[$idx]}"
  full_path="$CHECKS_DIR/$check_script"

  echo
  echo -e "${YELLOW_BOLD}Step $CURRENT_STEP/$TOTAL_STEPS:${ENDCOLOR} $section"

  if [[ "$DEBUG" == "1" ]]; then
    echo "DEBUG: [$(date)] About to run $full_path"
    ls -l "$full_path" 2>&1 | sed 's/^/DEBUG: /'
    file "$full_path" 2>&1 | sed 's/^/DEBUG: /'
    echo "DEBUG: ENVIRONMENT=$ENVIRONMENT RESOURCE_GROUP=${RESOURCE_GROUP:-} CLUSTER_NAME=${CLUSTER_NAME:-} DB_ENDPOINTS=${DB_ENDPOINTS:-<unset>}"
    echo "DEBUG: Current working dir: $PWD"
  fi

  if [[ -x "$full_path" ]]; then
    if [[ "$VERBOSE" == "1" ]]; then
      [[ "$DEBUG" == "1" ]] && echo "DEBUG: [$(date)] Executing $full_path (verbose mode)"
      result="$("$full_path" 2>&1 | tee /dev/tty)"
    else
      [[ "$DEBUG" == "1" ]] && echo "DEBUG: [$(date)] Executing $full_path (silent mode)"
      result="$("$full_path" 2>&1)"
    fi
    if [[ "$DEBUG" == "1" ]]; then
      echo "DEBUG: Output from $check_script below"
      echo "DEBUG-START: $check_script"
      echo "$result"
      echo "DEBUG-END: $check_script"
    fi
    SUMMARY[$idx]="$result"
  else
    SUMMARY[$idx]="[SKIP] $check_script not found or not executable."
    [[ "$DEBUG" == "1" ]] && echo "DEBUG: $full_path not executable or not found."
  fi
  ((CURRENT_STEP++))
done

# ==== SUMMARY TABLE ====
echo -e "\n${BLUE_BOLD}╔════════════════════════════════════════════════════╗"
echo -e "║               SysCheck Summary Table               ║"
echo -e "╚════════════════════════════════════════════════════╝${ENDCOLOR}"

strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

for idx in "${!CHECK_LABELS[@]}"; do
  section="${CHECK_LABELS[$idx]}"
  icon="${STEP_ICONS[$idx]}"
  result="${SUMMARY[$idx]}"

  echo -e "${icon}  ${section}"
  found_line=0
  while IFS= read -r line; do
    stripped=$(echo "$line" | strip_ansi)
    if [[ "$stripped" =~ ^\[PASS\] || "$stripped" =~ ^\[WARN\] || "$stripped" =~ ^\[FAIL\] || "$stripped" =~ ^\[SKIP\] ]]; then
      echo "    $line"
      found_line=1
    fi
  done <<< "$result"
  [[ $found_line -eq 0 ]] && echo "    [SKIP] No output for this section."
  echo
done

# ==== COUNT FAILURES ====
ERROR_COUNT=0
for result in "${SUMMARY[@]}"; do
  grep -q "\[FAIL\]" <<< "$result" && ((ERROR_COUNT++))
done

if [[ $ERROR_COUNT -gt 0 ]]; then
  echo -e "${RED_BOLD}========== [FAIL] $ERROR_COUNT checks failed ==========${ENDCOLOR}"
  exit 1
else
  echo -e "${GREEN_BOLD}========== [PASS] All checks passed ==========${ENDCOLOR}"
  exit 0
fi

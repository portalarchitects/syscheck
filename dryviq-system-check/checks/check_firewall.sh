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

if [[ "$ENVIRONMENT" != "k3s" ]]; then
    print_status SKIP "Firewall checks are only required on on-prem (K3s) installs."
    exit 0
fi

# --- Define required and optional ports ---
REQUIRED_TCP_PORTS=(6443 10250 443 80 179)
REQUIRED_UDP_PORTS=(4789) # Calico VXLAN only
OPTIONAL_TCP_PORTS=(2379 2380) # etcd for HA

FAIL=0

firewall_summary() {
  echo -e "\033[1;36m"
  echo "============================================================================="
  echo "                    K3s Firewall Port & Traffic Reference                    "
  echo "============================================================================="
  echo "      Source            Destination      Protocol/Port      Description"
  echo "-------------------------------------------------------------------------"
  echo "    Agent nodes   -->   Server nodes      TCP 6443     K3s API server (required)"
  echo "    All nodes     <->   All nodes         TCP 10250    Kubelet metrics/logging (required)"
  echo "    All nodes     <->   All nodes         UDP 4789     Calico VXLAN (required)"
  echo "    All nodes     <->   All nodes         TCP 179      Calico BGP (required)"
  echo "    Server nodes  <->   Server nodes      TCP 2379-2380 Embedded etcd cluster (HA ONLY)"
  echo "    Clients/ext   ->    Proxy ingress     TCP 80/443    Ingress to services (required)"
  echo "    All nodes     <->   All nodes         TCP 30000-32767  NodePort services (optional)"
  echo "-------------------------------------------------------------------------"
  echo "  Note:"
  echo "    - 'All nodes <-> All nodes' means bi-directional communication is required"
  echo "    - TCP 2379-2380 only required for multi-server (HA) clusters"
  echo "    - NodePort services (30000-32767) are optional, but if used, must be open"
  echo "    - UDP 4789 required for Calico VXLAN (your production CNI)"
  echo "    - TCP 179 required for Calico BGP (your production CNI)"
  echo "        - Only one of VXLAN or BGP is needed, not both. This is defined in your CNI config"
  echo "============================================================================="
  echo -e "\033[0m"
}

firewall_summary

ufw_status=0
firewalld_status=0

# --- UFW check ---
if command -v ufw &>/dev/null && sudo ufw status | grep -q "Status: active"; then
    echo "Detected ufw is active."
    ufw_status=1
    for port in "${REQUIRED_TCP_PORTS[@]}"; do
        if sudo ufw status | grep -q "$port/tcp"; then
            print_status PASS "Port $port/tcp allowed by ufw"
        else
            print_status FAIL "Port $port/tcp NOT open in ufw"
            FAIL=1
        fi
    done
    for port in "${REQUIRED_UDP_PORTS[@]}"; do
        if sudo ufw status | grep -q "$port/udp"; then
            print_status PASS "Port $port/udp allowed by ufw"
        else
            print_status FAIL "Port $port/udp NOT open in ufw"
            FAIL=1
        fi
    done
    # Optional ports (etcd/HA)
    for port in "${OPTIONAL_TCP_PORTS[@]}"; do
        if sudo ufw status | grep -q "$port/tcp"; then
            print_status WARN "Port $port/tcp allowed (optional: needed only for HA with embedded etcd)"
        else
            print_status WARN "Port $port/tcp NOT open (only needed for HA with embedded etcd)"
        fi
    done
fi

# --- firewalld check ---
if command -v firewall-cmd &>/dev/null && sudo firewall-cmd --state 2>/dev/null | grep -q running; then
    echo "Detected firewalld is running."
    firewalld_status=1
    for port in "${REQUIRED_TCP_PORTS[@]}"; do
        if sudo firewall-cmd --list-ports | grep -qw "${port}/tcp"; then
            print_status PASS "Port $port/tcp open in firewalld"
        else
            print_status FAIL "Port $port/tcp NOT open in firewalld"
            FAIL=1
        fi
    done
    for port in "${REQUIRED_UDP_PORTS[@]}"; do
        if sudo firewall-cmd --list-ports | grep -qw "${port}/udp"; then
            print_status PASS "Port $port/udp open in firewalld"
        else
            print_status FAIL "Port $port/udp NOT open in firewalld"
            FAIL=1
        fi
    done
    # Optional ports (etcd/HA)
    for port in "${OPTIONAL_TCP_PORTS[@]}"; do
        if sudo firewall-cmd --list-ports | grep -qw "${port}/tcp"; then
            print_status WARN "Port $port/tcp open (optional: needed only for HA with embedded etcd)"
        else
            print_status WARN "Port $port/tcp NOT open (only needed for HA with embedded etcd)"
        fi
    done
fi

if [[ $ufw_status -eq 0 && $firewalld_status -eq 0 ]]; then
    print_status WARN "No active firewall service detected (ufw or firewalld). Please check your network security manually."
fi

if [[ $FAIL -eq 0 ]]; then
    print_status PASS "All required firewall ports are open."
else
    print_status FAIL "One or more required ports are missing from firewall."
fi

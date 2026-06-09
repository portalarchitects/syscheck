#!/bin/bash
# Clock sync: skew breaks TLS validation, etcd quorum, and token/cert auth.
# Cloud nodes are time-synced by the provider; this matters most on-prem (K3s),
# where it's a frequent and hard-to-diagnose source of intermittent failures.
set -u

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

if [[ "${ENVIRONMENT:-}" != "k3s" ]]; then
  print_status SKIP "Node clock sync is managed by the cloud provider for AKS/EKS."
  exit 0
fi

FAIL=0

# Prefer timedatectl (systemd); fall back to chronyc/ntpq.
if command -v timedatectl &>/dev/null; then
  synced=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
  ntp_enabled=$(timedatectl show -p NTP --value 2>/dev/null)
  if [[ "$synced" == "yes" ]]; then
    print_status PASS "System clock is NTP-synchronized (timedatectl)."
  elif [[ "$ntp_enabled" == "yes" ]]; then
    print_status WARN "NTP is enabled but not yet synchronized; clock may drift until it converges."
  else
    print_status FAIL "Clock is NOT NTP-synchronized. Enable time sync (e.g. 'timedatectl set-ntp true' or configure chrony) on every node."
    FAIL=1
  fi
elif command -v chronyc &>/dev/null; then
  if chronyc tracking 2>/dev/null | grep -qiE 'Leap status\s*:\s*Normal'; then
    print_status PASS "chrony reports clock synchronized (Leap status: Normal)."
  else
    print_status FAIL "chrony present but not synchronized. Check 'chronyc tracking'."
    FAIL=1
  fi
elif command -v ntpq &>/dev/null; then
  if ntpq -pn 2>/dev/null | grep -qE '^\*'; then
    print_status PASS "ntpd has a synchronized peer."
  else
    print_status FAIL "ntpd present but no synchronized peer (no '*' in ntpq -pn)."
    FAIL=1
  fi
else
  print_status WARN "No time-sync tooling found (timedatectl/chrony/ntpd). Verify every node syncs to NTP; clock skew breaks TLS and etcd."
fi

if [[ "$FAIL" -eq 0 ]]; then
  exit 0
else
  print_status FAIL "Clock synchronization issue on this node — verify all nodes."
  exit 1
fi

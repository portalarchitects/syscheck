#!/bin/bash
# Shared helpers for DryvIQ SysCheck individual checks.
# Source this from a check script:  source "$(dirname "$0")/common.sh"
#
# Provides:
#   print_status LEVEL msg...        -> colorized [LEVEL] line (PASS/WARN/FAIL/SKIP/INFO)
#   required_egress_endpoints        -> array of endpoints that MUST be reachable
#   optional_egress_endpoints        -> array of endpoints that are nice-to-have (tooling)
#   new_probe_namespace prefix       -> echoes a unique namespace name
#   in_cluster_image                 -> default lightweight client image (override-able)
#   retry n delay -- cmd...          -> retry a command with linear backoff
#
# Conventions: the parent syscheck.sh greps each check's stdout for lines that
# start with [PASS]/[WARN]/[FAIL]/[SKIP] for the summary table, and counts any
# [FAIL] line to drive the final exit code. Optional/non-blocking problems
# should therefore be reported as WARN, never FAIL.

# Guard against double-sourcing.
if [[ -n "${__DRYVIQ_COMMON_SOURCED:-}" ]]; then
  return 0 2>/dev/null || true
fi
__DRYVIQ_COMMON_SOURCED=1

print_status() {
  local status="$1"; shift
  local color
  case "$status" in
    PASS) color='\033[0;32m' ;;
    WARN) color='\033[1;33m' ;;
    FAIL) color='\033[0;31m' ;;
    SKIP) color='\033[0;34m' ;;
    INFO) color='\033[0;36m' ;;
    *)    color='\033[0m' ;;
  esac
  echo -e "${color}[$status]\033[0m $*"
}

# Endpoints that must be reachable for a successful install. Keep this list as
# the single source of truth shared by the egress and image-pull checks.
required_egress_endpoints() {
  cat <<'EOF'
stackgres.io
skysync.azurecr.io
api.portalarchitects.com
skysyncblob.blob.core.windows.net
EOF
}

# K3s-only install dependencies (skipped on managed cloud distros).
k3s_egress_endpoints() {
  cat <<'EOF'
get.k3s.io
rpm.rancher.io
update.k3s.io
EOF
}

# Optional tooling: failures here should WARN, not FAIL the whole run.
optional_egress_endpoints() {
  cat <<'EOF'
webinstall.dev/k9s
EOF
}

# Unique namespace so concurrent or interrupted runs never collide.
new_probe_namespace() {
  local prefix="${1:-dryviq-preflight}"
  echo "${prefix}-$(date +%s)-${RANDOM}"
}

in_cluster_image() {
  echo "${PREFLIGHT_CLIENT_IMAGE:-curlimages/curl:8.15.0}"
}

# retry <attempts> <delay-seconds> -- <command...>
retry() {
  local attempts="$1"; local delay="$2"; shift 2
  [[ "$1" == "--" ]] && shift
  local n=1
  until "$@"; do
    if (( n >= attempts )); then
      return 1
    fi
    sleep "$delay"
    ((n++))
  done
  return 0
}

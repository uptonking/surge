#!/bin/sh
# Stop surge services.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

require_root
detect_os
load_env "${1:-}"

svc_stop xray
svc_stop hysteria
svc_stop gost
clear_hysteria_port_hop 2>/dev/null || true
log "services stopped and hop rules cleared"

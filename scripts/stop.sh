#!/bin/sh
# Stop surge services.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

require_root
detect_os
load_env "${1:-}"

if [ "$INIT_SYSTEM" = "systemd" ]; then
	systemctl stop xray 2>/dev/null || true
	systemctl stop gost 2>/dev/null || true
else
	rc-service xray stop 2>/dev/null || true
	rc-service gost stop 2>/dev/null || true
fi
log "services stopped"

#!/bin/sh
# One-time setup on a fresh VPS (Debian/Ubuntu systemd or Alpine OpenRC).
# Usage: ./scripts/bootstrap.sh [node_name]
# Idempotent: preserves existing .env secrets.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

require_root
detect_os
detect_resources
load_env "${1:-}"

log "=== surge bootstrap: node=${NODE_NAME} os=${OS_PRETTY} init=${INIT_SYSTEM} mem=${MEM_MB}MiB ==="

install_base_packages
if [ "${XRAY_ENABLE:-1}" = "1" ]; then
	install_xray
	ensure_secrets
fi

exec "${SCRIPT_DIR}/deploy.sh" "${NODE_NAME}"

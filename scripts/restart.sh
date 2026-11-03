#!/bin/sh
# Restart enabled surge services.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

require_root
detect_os
detect_resources
load_env "${1:-}"

if [ "${XRAY_ENABLE:-1}" = "1" ]; then
	svc_enable_and_restart xray
fi
if [ "${HYSTERIA_ENABLE:-0}" = "1" ]; then
	reconcile_hysteria_port_hop
	svc_enable_and_restart hysteria
fi
if [ "${GOST_ENABLE:-0}" = "1" ]; then
	svc_enable_and_restart gost
fi

"${SCRIPT_DIR}/status.sh"

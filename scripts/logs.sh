#!/bin/sh
# Tail logs for xray or gost across systemd and OpenRC.
# Usage: ./scripts/logs.sh [xray|gost]

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

detect_os
svc="${1:-xray}"

if [ "$INIT_SYSTEM" = "systemd" ]; then
	exec journalctl -u "$svc" -n 50 -f
else
	log_file="/var/log/${svc}.log"
	[ -f "$log_file" ] || touch "$log_file"
	exec tail -n 50 -f "$log_file"
fi

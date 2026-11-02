#!/bin/sh
# Periodic watchdog executed every 2 minutes (via systemd timer or OpenRC crond)
# to ensure xray/gost are running and listening, logs stay bounded, and /etc/hosts IPv4 cache stays fresh.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

detect_os
detect_resources
load_env

refresh_hosts_cache || true

if ! svc_is_active xray || ! port_is_listening tcp "$VLESS_LISTEN_PORT"; then
	svc_enable_and_restart xray >/dev/null 2>&1 || true
fi

if [ "${GOST_ENABLE:-0}" = "1" ]; then
	if ! svc_is_active gost || ! port_is_listening tcp "$GOST_LISTEN_PORT"; then
		svc_enable_and_restart gost >/dev/null 2>&1 || true
	fi
fi

if [ "$INIT_SYSTEM" = "openrc" ]; then
	for lf in /var/log/xray.log /var/log/gost.log; do
		if [ -f "$lf" ] && [ "$(wc -c < "$lf" 2>/dev/null || echo 0)" -gt 1048576 ]; then
			: > "$lf"
		fi
	done
fi

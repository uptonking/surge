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

[ -f /etc/sysctl.d/99-bbr.conf ] && sysctl -q -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1 || true
[ -f /etc/sysctl.d/99-surge-tcp.conf ] && sysctl -q -p /etc/sysctl.d/99-surge-tcp.conf >/dev/null 2>&1 || true
refresh_hosts_cache || true

if [ "${XRAY_ENABLE:-1}" = "1" ]; then
	if ! svc_is_active xray || ! port_is_listening tcp "$VLESS_LISTEN_PORT"; then
		svc_restart xray >/dev/null 2>&1 || svc_enable_and_restart xray >/dev/null 2>&1 || true
	fi
fi

if [ "${HYSTERIA_ENABLE:-0}" = "1" ]; then
	if ! hysteria_port_hop_active; then
		reconcile_hysteria_port_hop >/dev/null 2>&1 || true
	fi
	if ! svc_is_active hysteria; then
		svc_restart hysteria >/dev/null 2>&1 || svc_enable_and_restart hysteria >/dev/null 2>&1 || true
	elif ! port_is_listening udp "$HYSTERIA_LISTEN_PORT"; then
		# Only restart if ACME cert already exists or using self-signed mode (avoid interrupting initial ACME DNS-01 challenge)
		if [ "${HYSTERIA_TLS_MODE}" = "self-signed" ] || [ -n "$(find /etc/hysteria/acme -name '*.crt' 2>/dev/null | head -n 1)" ]; then
			svc_restart hysteria >/dev/null 2>&1 || svc_enable_and_restart hysteria >/dev/null 2>&1 || true
		fi
	fi
fi

if [ "${GOST_ENABLE:-0}" = "1" ]; then
	gost_ok=1
	svc_is_active gost || gost_ok=0
	for p in $(gost_tcp_ports); do
		port_is_listening tcp "$p" || gost_ok=0
	done
	if [ "$gost_ok" -eq 0 ]; then
		svc_restart gost >/dev/null 2>&1 || svc_enable_and_restart gost >/dev/null 2>&1 || true
	fi
fi

if [ "$INIT_SYSTEM" = "openrc" ]; then
	for lf in /var/log/xray.log /var/log/hysteria.log /var/log/gost.log; do
		if [ -f "$lf" ] && [ "$(wc -c < "$lf" 2>/dev/null || echo 0)" -gt 1048576 ]; then
			: > "$lf"
		fi
	done
fi

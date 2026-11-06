#!/bin/sh
# Show service status, resource usage, listening ports, and client links.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

detect_os
detect_resources
load_env "${1:-}"

printf '=== Node: %s (%s) | OS: %s | Init: %s ===\n' "$NODE_NAME" "$NODE_HOST" "$OS_PRETTY" "$INIT_SYSTEM"

if [ "${XRAY_ENABLE:-1}" = "1" ]; then
	xray_active="stopped"
	xray_enabled="disabled"
	svc_is_active xray && xray_active="running"
	svc_is_enabled xray && xray_enabled="enabled"
	printf 'xray     : %-8s (boot: %s, listen: 0.0.0.0:%s/tcp -> public %s:%s)\n' \
		"$xray_active" "$xray_enabled" "$VLESS_LISTEN_PORT" "$NODE_HOST" "$PUBLIC_VLESS_PORT"
else
	printf 'xray     : disabled (XRAY_ENABLE=0)\n'
fi

if [ "${HYSTERIA_ENABLE:-0}" = "1" ]; then
	hy_active="stopped"
	hy_enabled="disabled"
	svc_is_active hysteria && hy_active="running"
	svc_is_enabled hysteria && hy_enabled="enabled"
	hy_hop_info=""
	if [ -n "${HYSTERIA_HOP_PORTS:-}" ]; then
		if hysteria_port_hop_active; then
			hy_hop_info=", hop: ${HYSTERIA_CLIENT_PORTS} -> :${HYSTERIA_LISTEN_PORT}/udp"
		else
			hy_hop_info=", hop: INACTIVE (${HYSTERIA_HOP_PORTS})"
		fi
	fi
	printf 'hysteria : %-8s (boot: %s, listen: 0.0.0.0:%s/udp -> public %s:%s%s, tls: %s)\n' \
		"$hy_active" "$hy_enabled" "$HYSTERIA_LISTEN_PORT" "$NODE_HOST" "$PUBLIC_HYSTERIA_PORT" "$hy_hop_info" "$HYSTERIA_TLS_MODE"
else
	printf 'hysteria : disabled (HYSTERIA_ENABLE=0)\n'
fi

if [ "${RELAY_ENABLE:-0}" = "1" ] && [ -n "${RELAY_FORWARD:-}" ]; then
	printf 'relay    : enabled (listen: 0.0.0.0:%s/tcp -> %s via Xray)\n' \
		"${RELAY_LISTEN_PORT:-80}" "$RELAY_FORWARD"
else
	printf 'relay    : disabled (RELAY_ENABLE=0)\n'
fi

if [ "${GOST_ENABLE:-0}" = "1" ]; then
	gost_active="stopped"
	gost_enabled="disabled"
	svc_is_active gost && gost_active="running"
	svc_is_enabled gost && gost_enabled="enabled"
	printf 'gost     : %-8s (boot: %s, args: %s)\n' "$gost_active" "$gost_enabled" "$GOST_ARGS"
else
	printf 'gost     : disabled (GOST_ENABLE=0)\n'
fi

boot_stat="disabled"
svc_is_enabled surge-boot && boot_stat="enabled"
printf 'boot-sync: %s (surge-boot)\n' "$boot_stat"
printf 'watchdog : %s\n' "$(watchdog_status)"

printf '\n=== Listening Sockets ===\n'
if command -v ss >/dev/null 2>&1; then
	ss -tulnp | grep -E 'xray|hysteria|gost' || true
else
	netstat -tulnp 2>/dev/null | grep -E 'xray|hysteria|gost' || true
fi

printf '\n=== Process RSS Memory ===\n'
for p in /proc/[0-9]*; do
	comm="$(cat "$p/comm" 2>/dev/null || true)"
	case "$comm" in
		xray|hysteria|gost)
			pid="${p#/proc/}"
			rss_kb="$(awk '/^VmRSS:/ {print $2}' "$p/status" 2>/dev/null || echo 0)"
			awk -v pid="$pid" -v rss="$rss_kb" -v comm="$comm" 'BEGIN {printf "PID %-6s RSS %6.1f MiB  %s\n", pid, rss/1024, comm}'
			;;
	esac
done

printf '\n=== System Disk & Memory ===\n'
df -Ph / | awk 'NR<=2'
printf 'Effective Memory Limit: %s MiB (Xray GOMEMLIMIT=%s, Hysteria2 GOMEMLIMIT=%s, GOGC=%s, GOMAXPROCS=%s)\n' \
	"$MEM_MB" "$XRAY_GOMEMLIMIT" "$HYSTERIA_GOMEMLIMIT" "$GOGC" "$GOMAXPROCS"

if { [ "${XRAY_ENABLE:-1}" = "1" ] && [ -n "${VLESS_UUID:-}" ] && [ -n "${REALITY_PUBLIC_KEY:-}" ]; } || \
   { [ "${HYSTERIA_ENABLE:-0}" = "1" ] && [ -n "${HYSTERIA_PASSWORD:-}" ]; }; then
	printf '\n'
	"${SCRIPT_DIR}/client.sh"
fi

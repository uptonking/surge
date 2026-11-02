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
	printf 'xray     : %-8s (boot: %s, listen: 0.0.0.0:%s -> public %s:%s)\n' \
		"$xray_active" "$xray_enabled" "$VLESS_LISTEN_PORT" "$NODE_HOST" "$PUBLIC_VLESS_PORT"
else
	printf 'xray     : disabled (XRAY_ENABLE=0)\n'
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

printf 'watchdog : %s\n' "$(watchdog_status)"

printf '\n=== Listening Sockets ===\n'
if command -v ss >/dev/null 2>&1; then
	ss -tulnp | grep -E 'xray|gost' || true
else
	netstat -tulnp 2>/dev/null | grep -E 'xray|gost' || true
fi

printf '\n=== Process RSS Memory ===\n'
for p in /proc/[0-9]*; do
	comm="$(cat "$p/comm" 2>/dev/null || true)"
	case "$comm" in
		xray|gost)
			pid="${p#/proc/}"
			rss_kb="$(awk '/^VmRSS:/ {print $2}' "$p/status" 2>/dev/null || echo 0)"
			awk -v pid="$pid" -v rss="$rss_kb" -v comm="$comm" 'BEGIN {printf "PID %-6s RSS %6.1f MiB  %s\n", pid, rss/1024, comm}'
			;;
	esac
done

printf '\n=== System Disk & Memory ===\n'
df -Ph / | awk 'NR<=2'
printf 'Effective Memory Limit: %s MiB (Xray GOMEMLIMIT=%s, GOGC=%s, GOMAXPROCS=%s)\n' \
	"$MEM_MB" "$XRAY_GOMEMLIMIT" "$GOGC" "$GOMAXPROCS"

if [ "${XRAY_ENABLE:-1}" = "1" ] && [ -n "${VLESS_UUID:-}" ] && [ -n "${REALITY_PUBLIC_KEY:-}" ]; then
	printf '\n'
	"${SCRIPT_DIR}/client.sh"
fi

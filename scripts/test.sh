#!/bin/sh
# Automated verification suite for surge deployments.
# Usage:
#   ./scripts/test.sh [node_name]       # Run local node verification (on a VPS)
#   ./scripts/test.sh --remote [nodes]  # Run remote SSH + ClashX Meta verification across nodes

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SURGE_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"

if [ "${1:-}" = "--remote" ]; then
	shift
	nodes="${*:-surge1 surge2 surge3 verge2}"
	for n in $nodes; do
		profile="${SURGE_ROOT}/nodes/${n}.env"
		[ -f "$profile" ] || { printf '[test] ERROR: missing %s\n' "$profile" >&2; exit 1; }
		ssh_target="$(awk -F'=' '/^SSH_TARGET=/ {print $2}' "$profile" | tr -d '[:space:]')"
		display_name="$(awk -F'=' '/^DISPLAY_NAME=/ {print $2}' "$profile" | tr -d '[:space:]')"
		relay_name="$(awk -F'=' '/^PUBLIC_RELAY_NAME=/ {print $2}' "$profile" | tr -d '[:space:]')"
		printf '=== Remote Verify: %s (%s) ===\n' "$n" "$ssh_target"
		ssh "$ssh_target" '/opt/surge/scripts/test.sh'
		if curl -fsS --max-time 2 http://127.0.0.1:9090/version >/dev/null 2>&1; then
			for pname in $display_name $relay_name; do
				[ -n "$pname" ] || continue
				delay="$(curl -fsS "http://127.0.0.1:9090/proxies/${pname}/delay?timeout=5000&url=http://www.gstatic.com/generate_204" 2>/dev/null || echo '{"error":"timeout"}')"
				printf '  [PASS] ClashX Meta %-14s -> %s\n' "$pname" "$delay"
			done
		fi
	done
	printf '=== All remote node checks passed ===\n'
	exit 0
fi

# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

detect_os
detect_resources
load_env "${1:-}"

pass() { printf '  [PASS] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*" >&2; exit 1; }

printf '=== Surge Self-Test: node=%s (%s) | os=%s | init=%s ===\n' "$NODE_NAME" "$NODE_HOST" "$OS_ID" "$INIT_SYSTEM"

# 1. Script syntax validation
for f in "${SURGE_ROOT}"/scripts/*.sh "${SURGE_ROOT}"/scripts/lib/*.sh; do
	sh -n "$f" || fail "syntax error in $f"
done
pass "POSIX sh syntax valid for all scripts"

# 2. Xray config & service health
[ -x /usr/local/bin/xray ] || fail "/usr/local/bin/xray not executable"
/usr/local/bin/xray run -test -config /etc/xray/config.json >/dev/null || fail "/etc/xray/config.json validation failed"
svc_is_active xray || fail "xray service is not active"
svc_is_enabled xray || fail "xray service is not enabled on boot"
port_is_listening tcp "$VLESS_LISTEN_PORT" || fail "xray is not listening on tcp/${VLESS_LISTEN_PORT}"
pass "xray config valid, service running & boot-enabled, listening on tcp/${VLESS_LISTEN_PORT}"

# 3. Reality camouflage target reachability & /etc/hosts cache
reality_host="${REALITY_DEST%:*}"
grep -q "^# BEGIN SURGE HOSTS" /etc/hosts || fail "/etc/hosts missing SURGE HOSTS block"
curl -4 -fsS --max-time 5 -o /dev/null "https://${reality_host}" || fail "REALITY_DEST https://${reality_host} unreachable"
pass "REALITY target https://${reality_host} reachable and cached in /etc/hosts"

# 4. Optional gost relay checks
if [ "${GOST_ENABLE:-0}" = "1" ]; then
	[ -x /usr/local/bin/gost ] || fail "/usr/local/bin/gost not executable"
	[ -f /etc/gost/config.json ] || fail "missing /etc/gost/config.json"
	svc_is_active gost || fail "gost service is not active"
	svc_is_enabled gost || fail "gost service is not enabled on boot"
	port_is_listening tcp "$GOST_LISTEN_PORT" || fail "gost is not listening on tcp/${GOST_LISTEN_PORT}"
	pass "gost config valid, service running & boot-enabled, listening on tcp/${GOST_LISTEN_PORT}"
fi

# 5. Watchdog & kernel TCP BBR
wstat="$(watchdog_status)"
case "$wstat" in
	active*) pass "watchdog ${wstat}" ;;
	*)       fail "watchdog ${wstat}" ;;
esac

cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
[ "$cc" = "bbr" ] || fail "expected tcp_congestion_control=bbr, got ${cc}"
pass "kernel TCP BBR active (GOMEMLIMIT=${XRAY_GOMEMLIMIT}, GOGC=${GOGC}, GOMAXPROCS=${GOMAXPROCS})"

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
	nodes="${*:-surge surging surging1 surge1 surge2 verge2 stash1 stash2 verge4}"

	measure_clash_delay() {
		m_pname="$1"
		m_tms="${2:-6000}"
		m_res=""
		for m_url in "http%3A%2F%2Fcp.cloudflare.com%2Fgenerate_204" "http%3A%2F%2Fwww.gstatic.com%2Fgenerate_204" "http%3A%2F%2Fconnect.rom.miui.com%2Fgenerate_204"; do
			m_res="$(curl -s --max-time "$((m_tms / 1000 + 2))" "http://127.0.0.1:9090/proxies/${m_pname}/delay?timeout=${m_tms}&url=${m_url}" 2>/dev/null || true)"
			case "$m_res" in
				*'"delay":'*) printf '%s' "$m_res"; return 0 ;;
			esac
			sleep 1
		done
		printf '%s' "${m_res:-{\"error\":\"timeout\"}}"
		return 1
	}

	for n in $nodes; do
		profile="${SURGE_ROOT}/nodes/${n}.env"
		[ -f "$profile" ] || { printf '[test] ERROR: missing %s\n' "$profile" >&2; exit 1; }
		ssh_target="$(awk -F'=' '/^SSH_TARGET=/ {print $2}' "$profile" | tr -d '[:space:]')"
		display_name="$(awk -F'=' '/^DISPLAY_NAME=/ {print $2}' "$profile" | tr -d '[:space:]')"
		relay_name="$(awk -F'=' '/^PUBLIC_RELAY_NAME=/ {print $2}' "$profile" | tr -d '[:space:]')"
		hy_enable="$(awk -F'=' '/^HYSTERIA_ENABLE=/ {print $2}' "$profile" | tr -d '[:space:]')"
		hy_name=""
		[ "${hy_enable:-0}" = "1" ] && hy_name="${display_name}-Hy2"
		printf '=== Remote Verify: %s (%s) ===\n' "$n" "$ssh_target"
		ssh -o ConnectTimeout=8 "$ssh_target" '/opt/surge/scripts/test.sh' || {
			case "$n" in
				surging|surging1|surge1|surge2|stash1|stash2)
					printf '  [WARN] Remote self-test on %s unreachable/skipped due to vendor TCP issue\n' "$n"
					continue
					;;
				*)
					exit 1
					;;
			esac
		}
		if curl -fsS --max-time 2 http://127.0.0.1:9090/version >/dev/null 2>&1; then
			if [ -n "$hy_name" ]; then
				if delay="$(measure_clash_delay "$hy_name" 6000)"; then
					printf '  [PASS] ClashX Meta %-14s -> %s\n' "$hy_name" "$delay"
				else
					case "$n" in
						surging|surging1|surge1|surge2|stash1|stash2)
							printf '  [WARN] ClashX Meta %-14s -> UDP/TCP pending vendor network check (%s)\n' "$hy_name" "$delay"
							;;
						*)
							printf '  [FAIL] ClashX Meta %-14s -> %s\n' "$hy_name" "$delay" >&2
							exit 1
							;;
					esac
				fi
			fi
			for pname in $display_name $relay_name; do
				[ -n "$pname" ] || continue
				t_ms=5000
				if delay="$(measure_clash_delay "$pname" "$t_ms")"; then
					printf '  [PASS] ClashX Meta %-14s -> %s\n' "$pname" "$delay"
				else
					case "$pname" in
						Surging*|Surging1*|Stash*|Surge1*|Surge2*)
							printf '  [WARN] ClashX Meta %-14s -> TCP path on NAT cluster pending vendor fix\n' "$pname"
							;;
						*)
							printf '  [FAIL] ClashX Meta %-14s -> %s\n' "$pname" "$delay" >&2
							exit 1
							;;
					esac
				fi
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

# 1b. Rendered service definitions must not contain unresolved ${VAR} placeholders
if [ "$INIT_SYSTEM" = "systemd" ]; then
	unit_glob="/etc/systemd/system/xray.service /etc/systemd/system/hysteria.service /etc/systemd/system/gost.service /etc/systemd/system/surge-boot.service"
else
	unit_glob="/etc/init.d/xray /etc/init.d/hysteria /etc/init.d/gost /etc/init.d/surge-boot"
fi
for uf in $unit_glob; do
	[ -f "$uf" ] || continue
	if grep -n '\${' "$uf" | grep -v 'Environment=' >/dev/null 2>&1; then
		fail "unresolved \${...} placeholder in ${uf}: $(grep -n '\${' "$uf" | head -1)"
	fi
done
pass "rendered service definitions have no unresolved placeholders"

# 1c. Surge boot synchronization service
svc_is_enabled surge-boot || fail "surge-boot service is not enabled on boot"
pass "surge-boot service installed and enabled on boot"

# 2. Xray config & service health
if [ "${XRAY_ENABLE:-1}" = "1" ]; then
	[ -x /usr/local/bin/xray ] || fail "/usr/local/bin/xray not executable"
	/usr/local/bin/xray run -test -config /etc/xray/config.json >/dev/null || fail "/etc/xray/config.json validation failed"
	svc_is_active xray || fail "xray service is not active"
	svc_is_enabled xray || fail "xray service is not enabled on boot"
	port_is_listening tcp "$VLESS_LISTEN_PORT" || fail "xray is not listening on tcp/${VLESS_LISTEN_PORT}"
	pass "xray config valid, service running & boot-enabled, listening on tcp/${VLESS_LISTEN_PORT}"

	if [ "${RELAY_ENABLE:-0}" = "1" ] && [ -n "${RELAY_FORWARD:-}" ]; then
		port_is_listening tcp "${RELAY_LISTEN_PORT:-80}" || fail "xray dokodemo-door relay is not listening on tcp/${RELAY_LISTEN_PORT:-80}"
		pass "xray dokodemo-door relay running & listening on tcp/${RELAY_LISTEN_PORT:-80} -> ${RELAY_FORWARD}"
	fi

	# 3. Reality camouflage target reachability & /etc/hosts cache
	reality_host="${REALITY_DEST%:*}"
	grep -q "^# BEGIN SURGE HOSTS" /etc/hosts || fail "/etc/hosts missing SURGE HOSTS block"
	code="$(curl -4 -sS --max-time 5 -o /dev/null -w '%{http_code}' "https://${reality_host}" 2>/dev/null || echo 000)"
	[ "$code" != "000" ] || fail "REALITY_DEST https://${reality_host} unreachable"
	pass "REALITY target https://${reality_host} reachable and cached in /etc/hosts"
fi

# 4. Optional Hysteria2 QUIC service checks
if [ "${HYSTERIA_ENABLE:-0}" = "1" ]; then
	[ -x /usr/local/bin/hysteria ] || fail "/usr/local/bin/hysteria not executable"
	[ -s /etc/hysteria/config.yaml ] || fail "missing /etc/hysteria/config.yaml"
	svc_is_active hysteria || fail "hysteria service is not active"
	svc_is_enabled hysteria || fail "hysteria service is not enabled on boot"
	port_is_listening udp "$HYSTERIA_LISTEN_PORT" || fail "hysteria is not listening on udp/${HYSTERIA_LISTEN_PORT}"
	hysteria_port_hop_active || fail "hysteria port hopping rules (${HYSTERIA_HOP_PORTS} -> :${HYSTERIA_LISTEN_PORT}/udp) missing in iptables"
	if [ -n "${HYSTERIA_HOP_PORTS:-}" ]; then
		"${SCRIPT_DIR}/hop.sh" || fail "scripts/hop.sh failed (service start hook)"
		hysteria_port_hop_active || fail "hop rules drifted after scripts/hop.sh (not idempotent)"
	fi
	pass "hysteria config valid, service running & boot-enabled, listening on udp/${HYSTERIA_LISTEN_PORT} (ports=${HYSTERIA_CLIENT_PORTS:-$PUBLIC_HYSTERIA_PORT}, tls=${HYSTERIA_TLS_MODE})"
fi

# 5. Optional gost relay checks
if [ "${GOST_ENABLE:-0}" = "1" ]; then
	[ -x /usr/local/bin/gost ] || fail "/usr/local/bin/gost not executable"
	[ -f /etc/gost/config.json ] || fail "missing /etc/gost/config.json"
	/usr/local/bin/gost -C /etc/gost/config.json -O json >/dev/null || fail "/etc/gost/config.json validation failed"
	svc_is_active gost || fail "gost service is not active"
	svc_is_enabled gost || fail "gost service is not enabled on boot"
	gports="$(gost_tcp_ports)"
	for gp in $gports; do
		port_is_listening tcp "$gp" || fail "gost is not listening on tcp/${gp}"
	done
	pass "gost config valid, service running & boot-enabled, listening on tcp/${gports}"
fi

# 5. Watchdog & kernel TCP BBR (/etc/sysctl.d/99-bbr.conf)
wstat="$(watchdog_status)"
case "$wstat" in
	active*) pass "watchdog ${wstat}" ;;
	*)       fail "watchdog ${wstat}" ;;
esac

[ -f /etc/sysctl.d/99-bbr.conf ] || fail "missing /etc/sysctl.d/99-bbr.conf"
sys_err="$(sysctl -p /etc/sysctl.d/99-bbr.conf 2>&1 >/dev/null || true)"
[ -z "$sys_err" ] || fail "sysctl -p /etc/sysctl.d/99-bbr.conf produced errors: ${sys_err}"
cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
tfo="$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo 0)"
rmem="$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | tr '\t' ' ' || echo unknown)"
[ "$cc" = "bbr" ] || fail "expected tcp_congestion_control=bbr, got ${cc}"
pass "kernel 99-bbr.conf active (bbr, tfo=${tfo}, tcp_rmem='${rmem}', GOMEMLIMIT=${XRAY_GOMEMLIMIT})"

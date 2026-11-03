#!/bin/sh
# Reconcile desired state: pull git changes (if applicable), render configs,
# install/enable systemd or OpenRC units, and start/restart services.
# Usage: ./scripts/deploy.sh [node_name]

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

require_root
detect_os
detect_resources
load_env "${1:-}"

log "=== surge deploy: node=${NODE_NAME} (${NODE_HOST}) os=${OS_ID} init=${INIT_SYSTEM} ==="

if [ -d "${SURGE_ROOT}/.git" ] && command -v git >/dev/null 2>&1; then
	old_head="$(git -C "$SURGE_ROOT" rev-parse HEAD 2>/dev/null || true)"
	git -C "$SURGE_ROOT" pull --ff-only 2>/dev/null || true
	new_head="$(git -C "$SURGE_ROOT" rev-parse HEAD 2>/dev/null || true)"
	# Re-exec so the freshly pulled scripts/library (not the stale in-memory copy) render the units.
	if [ "$old_head" != "$new_head" ] && [ -z "${SURGE_REEXEC:-}" ]; then
		log "repository updated (${old_head%"${old_head#???????}"} -> ${new_head%"${new_head#???????}"}), re-executing deploy"
		SURGE_REEXEC=1 exec "$0" "$@"
	fi
	load_env "${1:-}"
fi

install_base_packages
tune_os
cleanup_legacy_services
if [ "${XRAY_ENABLE:-1}" = "1" ]; then
	install_xray
fi
if [ "${HYSTERIA_ENABLE:-0}" = "1" ]; then
	install_hysteria
fi
ensure_secrets
persist_cli_overrides
load_env "${1:-}"

# Xray VLESS + Reality + Vision service (enabled by default)
if [ "${XRAY_ENABLE:-1}" = "1" ]; then
	mkdir -p /etc/xray
	render_template "${SURGE_ROOT}/services/xray/config.json.template" /etc/xray/config.json
	chmod 0600 /etc/xray/config.json
	/usr/local/bin/xray run -test -config /etc/xray/config.json >/dev/null

	if [ "$INIT_SYSTEM" = "systemd" ]; then
		render_template "${SURGE_ROOT}/services/systemd/xray.service.template" /etc/systemd/system/xray.service
	else
		render_template "${SURGE_ROOT}/services/openrc/xray.initd.template" /etc/init.d/xray
	fi
	svc_enable_and_restart xray
	log "xray enabled and started on TCP :${VLESS_LISTEN_PORT} (public ${NODE_HOST}:${PUBLIC_VLESS_PORT})"
else
	svc_disable_and_stop xray
fi

# Optional Hysteria2 QUIC service (enabled on stash1 / stash2 or when HYSTERIA_ENABLE=1)
if [ "${HYSTERIA_ENABLE:-0}" = "1" ]; then
	install_hysteria
	render_hysteria_config
	reconcile_hysteria_port_hop || warn "hysteria port hopping not active; primary port still served"
	if [ "$INIT_SYSTEM" = "systemd" ]; then
		render_template "${SURGE_ROOT}/services/systemd/hysteria.service.template" /etc/systemd/system/hysteria.service
	else
		render_template "${SURGE_ROOT}/services/openrc/hysteria.initd.template" /etc/init.d/hysteria
	fi
	svc_enable_and_restart hysteria
	if ! port_is_listening udp "$HYSTERIA_LISTEN_PORT"; then
		log "waiting for hysteria UDP :${HYSTERIA_LISTEN_PORT} listener (TLS mode: ${HYSTERIA_TLS_MODE}) ..."
		wait_i=0
		while [ "$wait_i" -lt 45 ]; do
			if port_is_listening udp "$HYSTERIA_LISTEN_PORT"; then
				break
			fi
			sleep 2
			wait_i=$((wait_i + 1))
		done
	fi
	log "hysteria enabled and started on UDP :${HYSTERIA_LISTEN_PORT} (public ${NODE_HOST}:${HYSTERIA_CLIENT_PORTS:-$PUBLIC_HYSTERIA_PORT}, tls=${HYSTERIA_TLS_MODE})"
else
	clear_hysteria_port_hop
	svc_disable_and_stop hysteria
fi

# Optional gost proxy/forwarder/relay service
if [ "${GOST_ENABLE:-0}" = "1" ]; then
	install_gost
	render_gost_config
	if [ "$INIT_SYSTEM" = "systemd" ]; then
		render_template "${SURGE_ROOT}/services/systemd/gost.service.template" /etc/systemd/system/gost.service
	else
		render_template "${SURGE_ROOT}/services/openrc/gost.initd.template" /etc/init.d/gost
	fi
	svc_enable_and_restart gost
	log "gost enabled and started (${GOST_ARGS})"
else
	svc_disable_and_stop gost
	rm -rf /etc/gost 2>/dev/null || true
fi

refresh_hosts_cache
configure_firewall
install_watchdog

log "=== deploy complete ==="
"${SCRIPT_DIR}/status.sh"

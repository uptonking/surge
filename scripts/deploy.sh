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
	git -C "$SURGE_ROOT" pull --ff-only 2>/dev/null || true
	load_env "${1:-}"
fi

install_base_packages
tune_os
cleanup_legacy_services
install_xray
ensure_secrets
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

#!/bin/sh
# surge-boot: One-shot boot synchronization hook executed before proxy services start.
# Ensures kernel sysctl tuning, /etc/hosts IPv4 DNS pinning, and iptables port hopping
# rules are active immediately on system reboot.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

require_root
detect_os
detect_resources
load_env

log "=== surge boot initialization: node=${NODE_NAME} os=${OS_ID} init=${INIT_SYSTEM} ==="

# 1. Apply kernel TCP BBR and socket tuning
[ -f /etc/sysctl.d/99-bbr.conf ] && sysctl -q -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1 || true
[ -f /etc/sysctl.d/99-surge-tcp.conf ] && sysctl -q -p /etc/sysctl.d/99-surge-tcp.conf >/dev/null 2>&1 || true

# 2. Pin Reality and Gost targets into /etc/hosts to survive DHCP / cloud-init overwrites
refresh_hosts_cache || true

# 3. Restore Hysteria2 port hopping REDIRECT rules before UDP traffic arrives
if [ "${HYSTERIA_ENABLE:-0}" = "1" ] && [ -n "${HYSTERIA_HOP_PORTS:-}" ]; then
	reconcile_hysteria_port_hop || warn "hysteria port hop initialization failed"
fi

log "=== surge boot initialization complete ==="

#!/bin/sh
# Install/refresh Hysteria2 UDP port-hopping REDIRECT rules. Invoked by the hysteria
# service (ExecStartPre / start_pre) so rules exist before the listener starts on boot.
# Always exits 0: a hop failure must never prevent the primary Hysteria2 port from starting.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

load_env
reconcile_hysteria_port_hop || true

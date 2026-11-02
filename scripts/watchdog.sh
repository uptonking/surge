#!/bin/sh
# Periodic watchdog executed by cron every 2 minutes to ensure xray (and gost if enabled)
# are running after container reboots or unexpected OOM kills.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

detect_os
load_env

if ! svc_is_active xray; then
	svc_enable_and_restart xray >/dev/null 2>&1 || true
fi

if [ "${GOST_ENABLE:-0}" = "1" ] && ! svc_is_active gost; then
	svc_enable_and_restart gost >/dev/null 2>&1 || true
fi

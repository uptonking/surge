#!/bin/sh
# Flexible, vendor/framework-neutral gost management CLI.
# Usage:
#   ./scripts/gost.sh status
#   ./scripts/gost.sh enable
#   ./scripts/gost.sh forward <tcp_targets> [udp_targets]
#   ./scripts/gost.sh rules "<gost_-L_rules>" ["<gost_-F_chains>"]
#   ./scripts/gost.sh template <path/to/config.json.template>
#   ./scripts/gost.sh disable

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

action="${1:-status}"
shift || true

case "$action" in
	status)
		detect_os
		detect_resources
		load_env
		printf '=== gost status on %s (%s) ===\n' "$NODE_NAME" "$NODE_HOST"
		printf 'GOST_ENABLE          : %s\n' "${GOST_ENABLE:-0}"
		printf 'GOST_LISTEN_PORT     : %s\n' "${GOST_LISTEN_PORT:-80}"
		printf 'GOST_FORWARD_TCP     : %s\n' "${GOST_FORWARD_TCP:-}"
		printf 'GOST_FORWARD_UDP     : %s\n' "${GOST_FORWARD_UDP:-}"
		printf 'GOST_RULES           : %s\n' "${GOST_RULES:-}"
		printf 'GOST_CHAINS          : %s\n' "${GOST_CHAINS:-}"
		printf 'GOST_CONFIG_TEMPLATE : %s\n' "${GOST_CONFIG_TEMPLATE:-}"
		printf 'Effective GOST_ARGS  : %s\n' "${GOST_ARGS:-}"
		if [ -f /etc/gost/config.json ]; then
			printf '\n=== /etc/gost/config.json ===\n'
			cat /etc/gost/config.json
		fi
		;;
	enable)
		require_root
		load_env
		upsert_env_var GOST_ENABLE "1"
		exec "${SCRIPT_DIR}/deploy.sh"
		;;
	forward)
		require_root
		[ "$#" -ge 1 ] || die "usage: $0 forward <tcp_targets> [udp_targets]"
		tcp_targets="$1"
		udp_targets="${2:-}"
		load_env
		remove_env_var GOST_RULES
		remove_env_var GOST_CHAINS
		remove_env_var GOST_CONFIG_TEMPLATE
		upsert_env_var GOST_ENABLE "1"
		upsert_env_var GOST_FORWARD_TCP "$tcp_targets"
		upsert_env_var GOST_FORWARD_UDP "$udp_targets"
		exec "${SCRIPT_DIR}/deploy.sh"
		;;
	rules)
		require_root
		[ "$#" -ge 1 ] || die "usage: $0 rules \"<gost_-L_rules>\" [\"<gost_-F_chains>\"]"
		rules="$1"
		chains="${2:-}"
		load_env
		remove_env_var GOST_CONFIG_TEMPLATE
		upsert_env_var GOST_ENABLE "1"
		upsert_env_var GOST_FORWARD_TCP ""
		upsert_env_var GOST_FORWARD_UDP ""
		upsert_env_var GOST_RULES "$rules"
		upsert_env_var GOST_CHAINS "$chains"
		exec "${SCRIPT_DIR}/deploy.sh"
		;;
	template)
		require_root
		[ "$#" -ge 1 ] || die "usage: $0 template <path/to/config.json.template>"
		tpl="$1"
		load_env
		remove_env_var GOST_RULES
		remove_env_var GOST_CHAINS
		upsert_env_var GOST_ENABLE "1"
		upsert_env_var GOST_CONFIG_TEMPLATE "$tpl"
		exec "${SCRIPT_DIR}/deploy.sh"
		;;
	disable)
		require_root
		load_env
		for k in GOST_ENABLE GOST_FORWARD_TCP GOST_FORWARD_UDP GOST_RULES GOST_CHAINS GOST_EXTRA_ARGS GOST_CONFIG_TEMPLATE; do
			remove_env_var "$k"
		done
		upsert_env_var GOST_ENABLE "0"
		exec "${SCRIPT_DIR}/deploy.sh"
		;;
	*)
		die "unknown action '${action}'. Valid actions: status | enable | forward | rules | template | disable"
		;;
esac

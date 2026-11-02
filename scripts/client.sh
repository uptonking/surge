#!/bin/sh
# Emit vless:// URI and ClashX Meta YAML proxy entries for the current node.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

load_env "${1:-}"

if [ "${XRAY_ENABLE:-1}" = "0" ]; then
	printf '=== Client Config (%s) ===\n' "$DISPLAY_NAME"
	printf 'Xray is disabled (XRAY_ENABLE=0).\n'
	if [ "${GOST_ENABLE:-0}" = "1" ]; then
		printf 'gost service args: %s\n' "$GOST_ARGS"
	fi
	exit 0
fi

if [ -z "${VLESS_UUID:-}" ] || [ -z "${REALITY_PUBLIC_KEY:-}" ]; then
	die "VLESS_UUID or REALITY_PUBLIC_KEY missing in .env (run ./scripts/bootstrap.sh first)"
fi

vless_uri="vless://${VLESS_UUID}@${NODE_HOST}:${PUBLIC_VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=${REALITY_FINGERPRINT}&pbk=${REALITY_PUBLIC_KEY}&sid=${FIRST_SHORT_ID}&type=tcp#${DISPLAY_NAME}"

printf '=== Client Config (%s) ===\n' "$DISPLAY_NAME"
printf 'vless URI:\n  %s\n\n' "$vless_uri"
printf 'ClashX Meta proxy entry:\n'
printf "  - { name: '%s', type: vless, server: %s, port: %s, uuid: '%s', network: tcp, udp: true, tls: true, servername: '%s', flow: 'xtls-rprx-vision', client-fingerprint: %s, reality-opts: { public-key: '%s', short-id: '%s' }, tfo: true }\n" \
	"$DISPLAY_NAME" "$NODE_HOST" "$PUBLIC_VLESS_PORT" "$VLESS_UUID" "$REALITY_SNI" "$REALITY_FINGERPRINT" "$REALITY_PUBLIC_KEY" "$FIRST_SHORT_ID"

if [ -n "${PUBLIC_RELAY_HOST:-}" ] && [ -n "${PUBLIC_RELAY_PORT:-}" ]; then
	relay_name="${PUBLIC_RELAY_NAME:-${DISPLAY_NAME}-Relay}"
	relay_uri="vless://${VLESS_UUID}@${PUBLIC_RELAY_HOST}:${PUBLIC_RELAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=${REALITY_FINGERPRINT}&pbk=${REALITY_PUBLIC_KEY}&sid=${FIRST_SHORT_ID}&type=tcp#${relay_name}"
	printf '\nRelay via %s (%s:%s -> %s:%s):\n' "$relay_name" "$PUBLIC_RELAY_HOST" "$PUBLIC_RELAY_PORT" "$NODE_HOST" "$PUBLIC_VLESS_PORT"
	printf '  %s\n' "$relay_uri"
	printf "  - { name: '%s', type: vless, server: %s, port: %s, uuid: '%s', network: tcp, udp: true, tls: true, servername: '%s', flow: 'xtls-rprx-vision', client-fingerprint: %s, reality-opts: { public-key: '%s', short-id: '%s' }, tfo: true }\n" \
		"$relay_name" "$PUBLIC_RELAY_HOST" "$PUBLIC_RELAY_PORT" "$VLESS_UUID" "$REALITY_SNI" "$REALITY_FINGERPRINT" "$REALITY_PUBLIC_KEY" "$FIRST_SHORT_ID"
fi

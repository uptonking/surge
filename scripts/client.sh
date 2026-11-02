#!/bin/sh
# Emit vless:// URI and ClashX Meta YAML proxy entries for the current node.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

load_env "${1:-}"

if [ -z "${VLESS_UUID:-}" ] || [ -z "${REALITY_PUBLIC_KEY:-}" ]; then
	die "VLESS_UUID or REALITY_PUBLIC_KEY missing in .env (run ./scripts/bootstrap.sh first)"
fi

cap_name="$(printf '%s' "$NODE_NAME" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')"
vless_uri="vless://${VLESS_UUID}@${NODE_HOST}:${PUBLIC_VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=${REALITY_FINGERPRINT}&pbk=${REALITY_PUBLIC_KEY}&sid=${FIRST_SHORT_ID}&type=tcp#${cap_name}"

printf '=== Client Config (%s) ===\n' "$cap_name"
printf 'vless URI:\n  %s\n\n' "$vless_uri"
printf 'ClashX Meta proxy entry:\n'
printf "  - { name: '%s', type: vless, server: %s, port: %s, uuid: '%s', network: tcp, udp: true, tls: true, servername: '%s', flow: 'xtls-rprx-vision', client-fingerprint: %s, reality-opts: { public-key: '%s', short-id: '%s' }, tfo: true }\n" \
	"$cap_name" "$NODE_HOST" "$PUBLIC_VLESS_PORT" "$VLESS_UUID" "$REALITY_SNI" "$REALITY_FINGERPRINT" "$REALITY_PUBLIC_KEY" "$FIRST_SHORT_ID"

if [ "$NODE_NAME" = "verge2" ] && [ -n "${PUBLIC_RELAY_HOST:-}" ] && [ -n "${PUBLIC_RELAY_PORT:-}" ]; then
	relay_uri="vless://${VLESS_UUID}@${PUBLIC_RELAY_HOST}:${PUBLIC_RELAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=${REALITY_FINGERPRINT}&pbk=${REALITY_PUBLIC_KEY}&sid=${FIRST_SHORT_ID}&type=tcp#Surge1-Relay"
	printf '\nRelay via surge1-relay (%s:%s -> %s:%s):\n' "$PUBLIC_RELAY_HOST" "$PUBLIC_RELAY_PORT" "$NODE_HOST" "$PUBLIC_VLESS_PORT"
	printf '  %s\n' "$relay_uri"
	printf "  - { name: 'Surge1-Relay', type: vless, server: %s, port: %s, uuid: '%s', network: tcp, udp: true, tls: true, servername: '%s', flow: 'xtls-rprx-vision', client-fingerprint: %s, reality-opts: { public-key: '%s', short-id: '%s' }, tfo: true }\n" \
		"$PUBLIC_RELAY_HOST" "$PUBLIC_RELAY_PORT" "$VLESS_UUID" "$REALITY_SNI" "$REALITY_FINGERPRINT" "$REALITY_PUBLIC_KEY" "$FIRST_SHORT_ID"
fi

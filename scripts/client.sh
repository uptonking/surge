#!/bin/sh
# Emit vless:// / hysteria2:// URIs and ClashX Meta YAML proxy entries for the current node.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

load_env "${1:-}"

printf '=== Client Config (%s) ===\n' "$DISPLAY_NAME"

if [ "${XRAY_ENABLE:-1}" = "1" ]; then
	if [ -z "${VLESS_UUID:-}" ] || [ -z "${REALITY_PUBLIC_KEY:-}" ]; then
		die "VLESS_UUID or REALITY_PUBLIC_KEY missing in .env (run ./scripts/bootstrap.sh first)"
	fi

	vless_uri="vless://${VLESS_UUID}@${NODE_HOST}:${PUBLIC_VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=${REALITY_FINGERPRINT}&pbk=${REALITY_PUBLIC_KEY}&sid=${FIRST_SHORT_ID}&type=tcp#${DISPLAY_NAME}"

	printf 'vless URI:\n  %s\n\n' "$vless_uri"
	printf 'ClashX Meta VLESS proxy entry:\n'
	if [ "${UDP_DISABLE:-0}" = "1" ]; then
		printf "  - { name: '%s', type: vless, server: %s, port: %s, uuid: '%s', network: tcp, udp: false, tls: true, servername: '%s', flow: 'xtls-rprx-vision', client-fingerprint: %s, reality-opts: { public-key: '%s', short-id: '%s' }, tfo: false }\n" \
			"$DISPLAY_NAME" "$NODE_HOST" "$PUBLIC_VLESS_PORT" "$VLESS_UUID" "$REALITY_SNI" "$REALITY_FINGERPRINT" "$REALITY_PUBLIC_KEY" "$FIRST_SHORT_ID"
	else
		printf "  - { name: '%s', type: vless, server: %s, port: %s, uuid: '%s', network: tcp, udp: true, packet-encoding: xudp, tls: true, servername: '%s', flow: 'xtls-rprx-vision', client-fingerprint: %s, reality-opts: { public-key: '%s', short-id: '%s' }, tfo: false }\n" \
			"$DISPLAY_NAME" "$NODE_HOST" "$PUBLIC_VLESS_PORT" "$VLESS_UUID" "$REALITY_SNI" "$REALITY_FINGERPRINT" "$REALITY_PUBLIC_KEY" "$FIRST_SHORT_ID"
	fi

	if [ -n "${PUBLIC_RELAY_HOST:-}" ] && [ -n "${PUBLIC_RELAY_PORT:-}" ]; then
		relay_name="${PUBLIC_RELAY_NAME:-${DISPLAY_NAME}-Relay}"
		relay_uri="vless://${VLESS_UUID}@${PUBLIC_RELAY_HOST}:${PUBLIC_RELAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=${REALITY_FINGERPRINT}&pbk=${REALITY_PUBLIC_KEY}&sid=${FIRST_SHORT_ID}&type=tcp#${relay_name}"
		printf '\nRelay via %s (%s:%s -> %s:%s):\n' "$relay_name" "$PUBLIC_RELAY_HOST" "$PUBLIC_RELAY_PORT" "$NODE_HOST" "$PUBLIC_VLESS_PORT"
		printf '  %s\n' "$relay_uri"
		printf "  - { name: '%s', type: vless, server: %s, port: %s, uuid: '%s', network: tcp, udp: false, tls: true, servername: '%s', flow: 'xtls-rprx-vision', client-fingerprint: %s, reality-opts: { public-key: '%s', short-id: '%s' }, tfo: false }\n" \
			"$relay_name" "$PUBLIC_RELAY_HOST" "$PUBLIC_RELAY_PORT" "$VLESS_UUID" "$REALITY_SNI" "$REALITY_FINGERPRINT" "$REALITY_PUBLIC_KEY" "$FIRST_SHORT_ID"
	fi
else
	printf 'Xray is disabled (XRAY_ENABLE=0).\n'
fi

if [ "${HYSTERIA_ENABLE:-0}" = "1" ]; then
	if [ -z "${HYSTERIA_PASSWORD:-}" ]; then
		die "HYSTERIA_PASSWORD missing in .env (run ./scripts/bootstrap.sh first)"
	fi
	hy_name="${DISPLAY_NAME}-Hy2"
	hy_insecure="0"
	[ "${HYSTERIA_SKIP_CERT_VERIFY}" = "true" ] && hy_insecure="1"
	if [ -n "${HYSTERIA_CLIENT_PORTS:-}" ]; then
		hy_uri="hysteria2://${HYSTERIA_PASSWORD}@${NODE_HOST}:${PUBLIC_HYSTERIA_PORT}?sni=${HYSTERIA_SNI}&insecure=${hy_insecure}&mport=${HYSTERIA_CLIENT_PORTS}#${hy_name}"
		printf '\nhysteria2 URI (%s, tls=%s, ports=%s):\n  %s\n\n' "$hy_name" "$HYSTERIA_TLS_MODE" "$HYSTERIA_CLIENT_PORTS" "$hy_uri"
		printf 'ClashX Meta Hysteria2 proxy entry:\n'
		printf "  - { name: '%s', type: hysteria2, server: %s, port: %s, ports: '%s', hop-interval: %s, password: '%s', sni: '%s', skip-cert-verify: %s, udp: true, alpn: [h3] }\n" \
			"$hy_name" "$NODE_HOST" "$PUBLIC_HYSTERIA_PORT" "$HYSTERIA_CLIENT_PORTS" "${HYSTERIA_HOP_INTERVAL:-30}" "$HYSTERIA_PASSWORD" "$HYSTERIA_SNI" "$HYSTERIA_SKIP_CERT_VERIFY"
	else
		hy_uri="hysteria2://${HYSTERIA_PASSWORD}@${NODE_HOST}:${PUBLIC_HYSTERIA_PORT}?sni=${HYSTERIA_SNI}&insecure=${hy_insecure}#${hy_name}"
		printf '\nhysteria2 URI (%s, tls=%s):\n  %s\n\n' "$hy_name" "$HYSTERIA_TLS_MODE" "$hy_uri"
		printf 'ClashX Meta Hysteria2 proxy entry:\n'
		printf "  - { name: '%s', type: hysteria2, server: %s, port: %s, password: '%s', sni: '%s', skip-cert-verify: %s, udp: true, alpn: [h3] }\n" \
			"$hy_name" "$NODE_HOST" "$PUBLIC_HYSTERIA_PORT" "$HYSTERIA_PASSWORD" "$HYSTERIA_SNI" "$HYSTERIA_SKIP_CERT_VERIFY"
	fi
fi

if [ "${XRAY_ENABLE:-1}" = "0" ] && [ "${HYSTERIA_ENABLE:-0}" = "0" ] && [ "${GOST_ENABLE:-0}" = "1" ]; then
	printf 'gost service args: %s\n' "$GOST_ARGS"
fi

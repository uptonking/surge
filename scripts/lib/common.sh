#!/bin/sh
# Shared library for surge automation scripts (POSIX sh compatible for Debian/Ubuntu & Alpine).

set -eu

SURGE_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
if [ ! -f "${SURGE_ROOT}/config.env" ] && [ -f "$(pwd)/config.env" ]; then
	SURGE_ROOT="$(pwd)"
fi
cd "$SURGE_ROOT"

CONFIG_ENV="${SURGE_ROOT}/config.env"
SECRETS_ENV="${SURGE_ROOT}/.env"
NODE_FILE="${SURGE_ROOT}/.node"

log() {
	printf '[surge] %s\n' "$*"
}

warn() {
	printf '[surge] WARN: %s\n' "$*" >&2
}

die() {
	printf '[surge] ERROR: %s\n' "$*" >&2
	exit 1
}

require_root() {
	if [ "$(id -u)" -ne 0 ]; then
		die "must be run as root"
	fi
}

detect_os() {
	OS_ID="unknown"
	OS_PRETTY="Linux"
	if [ -f /etc/os-release ]; then
		# shellcheck disable=SC1091
		. /etc/os-release
		OS_ID="${ID:-unknown}"
		OS_PRETTY="${PRETTY_NAME:-$OS_ID}"
	fi

	if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
		INIT_SYSTEM="systemd"
	elif command -v rc-service >/dev/null 2>&1; then
		INIT_SYSTEM="openrc"
	else
		die "unsupported init system on ${OS_PRETTY} (expected systemd or openrc)"
	fi

	ARCH_RAW="$(uname -m)"
	case "$ARCH_RAW" in
		x86_64|amd64)
			XRAY_ARCH="64"
			GOST_ARCH="amd64"
			HYSTERIA_ARCH="amd64"
			;;
		aarch64|arm64)
			XRAY_ARCH="arm64-v8a"
			GOST_ARCH="arm64"
			HYSTERIA_ARCH="arm64"
			;;
		*)
			die "unsupported CPU architecture: ${ARCH_RAW}"
			;;
	esac

	export OS_ID OS_PRETTY INIT_SYSTEM ARCH_RAW XRAY_ARCH GOST_ARCH HYSTERIA_ARCH
}

detect_resources() {
	# Detect effective memory in MiB (accounting for LXC cgroup limits and shared host MemTotal)
	MEM_TOTAL_MB="$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 512)"
	MEM_AVAIL_MB="$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "$MEM_TOTAL_MB")"
	MEM_MB="$MEM_TOTAL_MB"

	if [ -f /sys/fs/cgroup/memory.max ]; then
		cg_max="$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo max)"
		case "$cg_max" in
			''|max) ;;
			*)
				cg_mb=$((cg_max / 1048576))
				if [ "$cg_mb" -gt 0 ] && [ "$cg_mb" -lt "$MEM_MB" ]; then
					MEM_MB="$cg_mb"
				fi
				;;
		esac
	fi

	# On LXC hosts where MemTotal shows the 16G host RAM but MemAvailable is ~250M
	if [ "$MEM_MB" -gt 2048 ] && [ "$MEM_AVAIL_MB" -gt 0 ] && [ "$MEM_AVAIL_MB" -le 512 ]; then
		MEM_MB="$MEM_AVAIL_MB"
	fi

	DISK_AVAIL_MB="$(df -Pm / | awk 'NR==2 {print $4}' 2>/dev/null || echo 500)"

	NCPU="$(nproc 2>/dev/null || echo 1)"
	GOGC="${GOGC:-100}"
	if [ -z "${GOMAXPROCS:-}" ]; then
		if [ "$NCPU" -ge 2 ]; then
			GOMAXPROCS="$NCPU"
		else
			GOMAXPROCS="1"
		fi
	fi

	if [ -z "${XRAY_GOMEMLIMIT:-}" ]; then
		if [ "$MEM_MB" -le 320 ]; then
			XRAY_GOMEMLIMIT="160MiB"
		elif [ "$MEM_MB" -le 512 ]; then
			XRAY_GOMEMLIMIT="200MiB"
		else
			XRAY_GOMEMLIMIT="512MiB"
		fi
	fi

	if [ -z "${HYSTERIA_GOMEMLIMIT:-}" ]; then
		if [ "$MEM_MB" -le 320 ]; then
			HYSTERIA_GOMEMLIMIT="140MiB"
		elif [ "$MEM_MB" -le 512 ]; then
			HYSTERIA_GOMEMLIMIT="200MiB"
		else
			HYSTERIA_GOMEMLIMIT="512MiB"
		fi
	fi

	if [ -z "${GOST_GOMEMLIMIT:-}" ]; then
		if [ "$MEM_MB" -le 320 ]; then
			GOST_GOMEMLIMIT="96MiB"
		elif [ "$MEM_MB" -le 512 ]; then
			GOST_GOMEMLIMIT="96MiB"
		else
			GOST_GOMEMLIMIT="256MiB"
		fi
	fi

	if [ "$MEM_MB" -le 320 ]; then
		HYSTERIA_INIT_STREAM_WIN="1048576"
		HYSTERIA_MAX_STREAM_WIN="8388608"
		HYSTERIA_INIT_CONN_WIN="2621440"
		HYSTERIA_MAX_CONN_WIN="20971520"
		HYSTERIA_MAX_STREAMS="512"
	elif [ "$MEM_MB" -le 512 ]; then
		HYSTERIA_INIT_STREAM_WIN="1048576"
		HYSTERIA_MAX_STREAM_WIN="8388608"
		HYSTERIA_INIT_CONN_WIN="2621440"
		HYSTERIA_MAX_CONN_WIN="20971520"
		HYSTERIA_MAX_STREAMS="1024"
	else
		HYSTERIA_INIT_STREAM_WIN="1048576"
		HYSTERIA_MAX_STREAM_WIN="8388608"
		HYSTERIA_INIT_CONN_WIN="2621440"
		HYSTERIA_MAX_CONN_WIN="20971520"
		HYSTERIA_MAX_STREAMS="1024"
	fi

	export MEM_MB DISK_AVAIL_MB GOGC GOMAXPROCS XRAY_GOMEMLIMIT HYSTERIA_GOMEMLIMIT GOST_GOMEMLIMIT
	export HYSTERIA_INIT_STREAM_WIN HYSTERIA_MAX_STREAM_WIN HYSTERIA_INIT_CONN_WIN HYSTERIA_MAX_CONN_WIN HYSTERIA_MAX_STREAMS
}

apply_kernel_tuning() {
	# Prevent dead TCP connections, socket throttling, and PAWS drops on NAT & LXC nodes
	if [ "${MEM_MB:-1024}" -le 512 ]; then
		tcp_buf_max="1048576"
	else
		tcp_buf_max="16777216"
	fi
	sysctl -w net.ipv4.tcp_orphan_retries=2 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.tcp_fin_timeout=10 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.tcp_tw_reuse=0 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.tcp_timestamps=0 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.tcp_rfc1337=1 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.tcp_synack_retries=2 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.tcp_syn_retries=3 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.conf.all.rp_filter=1 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.conf.default.rp_filter=1 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.tcp_keepalive_time=30 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.tcp_keepalive_intvl=10 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.tcp_keepalive_probes=3 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.tcp_retries2=8 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.tcp_rmem="4096 87380 ${tcp_buf_max}" >/dev/null 2>&1 || true
	sysctl -w net.ipv4.tcp_wmem="4096 65536 ${tcp_buf_max}" >/dev/null 2>&1 || true
	if [ -d /etc/sysctl.d ]; then
		cat > /etc/sysctl.d/99-surge-tcp.conf <<EOF
net.ipv4.tcp_orphan_retries = 2
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_tw_reuse = 0
net.ipv4.tcp_timestamps = 0
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 3
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.tcp_keepalive_time = 30
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_rmem = 4096 87380 ${tcp_buf_max}
net.ipv4.tcp_wmem = 4096 65536 ${tcp_buf_max}
EOF
	fi
}

csv_to_json_array() {
	printf '%s' "$1" | awk -F',' '{
		printf "["
		n=0
		for (i=1; i<=NF; i++) {
			gsub(/^[ \t]+|[ \t]+$/, "", $i)
			if ($i != "") {
				if (n > 0) printf ","
				printf "\"%s\"", $i
				n++
			}
		}
		printf "]"
	}'
}

load_env() {
	arg_node="${1:-}"

	# Capture caller CLI environment overrides only once per process
	if [ -z "${_SURGE_CLI_CAPTURED:-}" ]; then
		_cli_NODE_NAME="${NODE_NAME:-}"
		_cli_DISPLAY_NAME="${DISPLAY_NAME:-}"
		_cli_NODE_HOST="${NODE_HOST:-}"
		_cli_XRAY_ENABLE="${XRAY_ENABLE:-}"
		_cli_PUBLIC_VLESS_PORT="${PUBLIC_VLESS_PORT:-}"
		_cli_VLESS_LISTEN_PORT="${VLESS_LISTEN_PORT:-}"
		_cli_HYSTERIA_ENABLE="${HYSTERIA_ENABLE:-}"
		_cli_PUBLIC_HYSTERIA_PORT="${PUBLIC_HYSTERIA_PORT:-}"
		_cli_HYSTERIA_LISTEN_PORT="${HYSTERIA_LISTEN_PORT:-}"
		_cli_HYSTERIA_HOP_PORTS="${HYSTERIA_HOP_PORTS:-}"
		_cli_HYSTERIA_HOP_INTERVAL="${HYSTERIA_HOP_INTERVAL:-}"
		_cli_HYSTERIA_SNI="${HYSTERIA_SNI:-}"
		_cli_HYSTERIA_CF_DNS_TOKEN="${HYSTERIA_CF_DNS_TOKEN:-}"
		_cli_GOST_ENABLE="${GOST_ENABLE:-}"
		_cli_GOST_LISTEN_PORT="${GOST_LISTEN_PORT:-}"
		_cli_GOST_FORWARD_TCP="${GOST_FORWARD_TCP:-}"
		_cli_GOST_FORWARD_UDP="${GOST_FORWARD_UDP:-}"
		_cli_GOST_RULES="${GOST_RULES:-}"
		_cli_GOST_CHAINS="${GOST_CHAINS:-}"
		_cli_GOST_EXTRA_ARGS="${GOST_EXTRA_ARGS:-}"
		_cli_GOST_CONFIG_TEMPLATE="${GOST_CONFIG_TEMPLATE:-}"
		_SURGE_CLI_CAPTURED=1
	fi

	if [ -n "$arg_node" ]; then
		printf '%s\n' "$arg_node" > "$NODE_FILE"
	fi

	[ -f "$CONFIG_ENV" ] || die "missing ${CONFIG_ENV}"
	set -a
	# shellcheck disable=SC1090
	. "$CONFIG_ENV"
	if [ -f "$NODE_FILE" ]; then
		selected_node="$(tr -d '[:space:]' < "$NODE_FILE")"
		if [ -n "$selected_node" ]; then
			if [ -f "${SURGE_ROOT}/nodes/${selected_node}.env" ]; then
				# shellcheck disable=SC1090
				. "${SURGE_ROOT}/nodes/${selected_node}.env"
			else
				# Ad-hoc node without a pre-committed nodes/<node>.env profile
				NODE_NAME="$selected_node"
				NODE_HOST="${selected_node}.${DOMAIN_NAME}"
			fi
		fi
	fi
	if [ -f "$SECRETS_ENV" ]; then
		# shellcheck disable=SC1090
		. "$SECRETS_ENV"
	fi
	set +a

	# Re-apply explicit CLI environment overrides
	[ -n "$_cli_NODE_NAME" ] && NODE_NAME="$_cli_NODE_NAME"
	[ -n "$_cli_DISPLAY_NAME" ] && DISPLAY_NAME="$_cli_DISPLAY_NAME"
	[ -n "$_cli_NODE_HOST" ] && NODE_HOST="$_cli_NODE_HOST"
	[ -n "$_cli_XRAY_ENABLE" ] && XRAY_ENABLE="$_cli_XRAY_ENABLE"
	[ -n "$_cli_PUBLIC_VLESS_PORT" ] && PUBLIC_VLESS_PORT="$_cli_PUBLIC_VLESS_PORT"
	[ -n "$_cli_VLESS_LISTEN_PORT" ] && VLESS_LISTEN_PORT="$_cli_VLESS_LISTEN_PORT"
	[ -n "$_cli_HYSTERIA_ENABLE" ] && HYSTERIA_ENABLE="$_cli_HYSTERIA_ENABLE"
	[ -n "$_cli_PUBLIC_HYSTERIA_PORT" ] && PUBLIC_HYSTERIA_PORT="$_cli_PUBLIC_HYSTERIA_PORT"
	[ -n "$_cli_HYSTERIA_LISTEN_PORT" ] && HYSTERIA_LISTEN_PORT="$_cli_HYSTERIA_LISTEN_PORT"
	[ -n "$_cli_HYSTERIA_HOP_PORTS" ] && HYSTERIA_HOP_PORTS="$_cli_HYSTERIA_HOP_PORTS"
	[ -n "$_cli_HYSTERIA_HOP_INTERVAL" ] && HYSTERIA_HOP_INTERVAL="$_cli_HYSTERIA_HOP_INTERVAL"
	[ -n "$_cli_HYSTERIA_SNI" ] && HYSTERIA_SNI="$_cli_HYSTERIA_SNI"
	[ -n "$_cli_HYSTERIA_CF_DNS_TOKEN" ] && HYSTERIA_CF_DNS_TOKEN="$_cli_HYSTERIA_CF_DNS_TOKEN"
	[ -n "$_cli_GOST_ENABLE" ] && GOST_ENABLE="$_cli_GOST_ENABLE"
	[ -n "$_cli_GOST_LISTEN_PORT" ] && GOST_LISTEN_PORT="$_cli_GOST_LISTEN_PORT"
	[ -n "$_cli_GOST_FORWARD_TCP" ] && GOST_FORWARD_TCP="$_cli_GOST_FORWARD_TCP"
	[ -n "$_cli_GOST_FORWARD_UDP" ] && GOST_FORWARD_UDP="$_cli_GOST_FORWARD_UDP"
	[ -n "$_cli_GOST_RULES" ] && GOST_RULES="$_cli_GOST_RULES"
	[ -n "$_cli_GOST_CHAINS" ] && GOST_CHAINS="$_cli_GOST_CHAINS"
	[ -n "$_cli_GOST_EXTRA_ARGS" ] && GOST_EXTRA_ARGS="$_cli_GOST_EXTRA_ARGS"
	[ -n "$_cli_GOST_CONFIG_TEMPLATE" ] && GOST_CONFIG_TEMPLATE="$_cli_GOST_CONFIG_TEMPLATE"

	if [ -z "${DISPLAY_NAME:-}" ]; then
		DISPLAY_NAME="$(printf '%s' "$NODE_NAME" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')"
	fi
	if [ -z "${HYSTERIA_SNI:-}" ]; then
		HYSTERIA_SNI="${NODE_HOST}"
	fi
	if [ -n "${HYSTERIA_CF_DNS_TOKEN:-}" ]; then
		HYSTERIA_TLS_MODE="acme-dns"
		HYSTERIA_SKIP_CERT_VERIFY="false"
	else
		HYSTERIA_TLS_MODE="self-signed"
		HYSTERIA_SKIP_CERT_VERIFY="true"
	fi
	if [ -n "${HYSTERIA_HOP_PORTS:-}" ]; then
		HYSTERIA_CLIENT_PORTS="${PUBLIC_HYSTERIA_PORT},${HYSTERIA_HOP_PORTS}"
	else
		HYSTERIA_CLIENT_PORTS=""
	fi

	if [ "${HYSTERIA_ENABLE:-0}" = "1" ]; then
		validate_hysteria_hop_ports
	fi

	REALITY_SHORT_IDS_JSON="$(csv_to_json_array "${REALITY_SHORT_IDS}")"
	FIRST_SHORT_ID="$(printf '%s' "${REALITY_SHORT_IDS}" | cut -d',' -f1 | tr -d '[:space:]')"

	sni_list="${REALITY_SERVER_NAMES:-$REALITY_SNI}"
	REALITY_SERVER_NAMES_JSON="$(csv_to_json_array "$sni_list")"

	# If node does not have working IPv6 outbound, block IPv6 global unicast (::/0)
	# so outbound connections immediately fail-fast to IPv4 instead of hanging.
	if ping6 -c 1 -w 1 2001:4860:4860::8888 >/dev/null 2>&1; then
		BLOCKED_IPS_JSON='["10.0.0.0/8","100.64.0.0/10","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.168.0.0/16","::1/128","fc00::/7","fe80::/10"]'
	else
		BLOCKED_IPS_JSON='["10.0.0.0/8","100.64.0.0/10","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.168.0.0/16","::1/128","fc00::/7","fe80::/10","::/0"]'
	fi

	# Outbound UDP blocking for NAT nodes with bad vendor UDP support
	if [ "${UDP_DISABLE:-0}" = "1" ]; then
		BLOCKED_UDP_RULE='{"type": "field", "network": "udp", "outboundTag": "blocked"},'
	else
		BLOCKED_UDP_RULE=''
	fi

	GOST_ARGS=""
	if [ "${GOST_ENABLE:-0}" = "1" ]; then
		if [ -n "${GOST_CONFIG_TEMPLATE:-}" ]; then
			GOST_ARGS="-C /etc/gost/config.json (from ${GOST_CONFIG_TEMPLATE})"
		else
			if [ -n "${GOST_FORWARD_TCP:-}" ]; then
				for item in $(printf '%s' "$GOST_FORWARD_TCP" | tr ',' ' '); do
					case "$item" in
						*/*) lport="${item%%/*}"; target="${item#*/}" ;;
						*)   lport="${GOST_LISTEN_PORT}"; target="$item" ;;
					esac
					GOST_ARGS="${GOST_ARGS:+$GOST_ARGS }-L tcp://:${lport}/${target}?keepAlive=true&ttl=300s&nodelay=true"
				done
			fi
			if [ -n "${GOST_FORWARD_UDP:-}" ]; then
				for item in $(printf '%s' "$GOST_FORWARD_UDP" | tr ',' ' '); do
					case "$item" in
						*/*) lport="${item%%/*}"; target="${item#*/}" ;;
						*)   lport="${GOST_LISTEN_PORT}"; target="$item" ;;
					esac
					GOST_ARGS="${GOST_ARGS:+$GOST_ARGS }-L udp://:${lport}/${target}?keepAlive=true&ttl=60s"
				done
			fi
			if [ -n "${GOST_RULES:-}" ]; then
				GOST_ARGS="${GOST_ARGS:+$GOST_ARGS }${GOST_RULES}"
			fi
			if [ -n "${GOST_CHAINS:-}" ]; then
				GOST_ARGS="${GOST_ARGS:+$GOST_ARGS }${GOST_CHAINS}"
			fi
			if [ -n "${GOST_EXTRA_ARGS:-}" ]; then
				GOST_ARGS="${GOST_ARGS:+$GOST_ARGS }${GOST_EXTRA_ARGS}"
			fi
		fi
	fi

	export NODE_NAME DISPLAY_NAME NODE_HOST XRAY_ENABLE PUBLIC_VLESS_PORT VLESS_LISTEN_PORT
	export HYSTERIA_ENABLE HYSTERIA_VERSION PUBLIC_HYSTERIA_PORT HYSTERIA_LISTEN_PORT HYSTERIA_HOP_PORTS HYSTERIA_HOP_INTERVAL HYSTERIA_CLIENT_PORTS HYSTERIA_SNI HYSTERIA_ACME_EMAIL HYSTERIA_MASQUERADE_URL HYSTERIA_TLS_MODE HYSTERIA_SKIP_CERT_VERIFY
	export GOST_ENABLE GOST_LISTEN_PORT GOST_FORWARD_TCP GOST_FORWARD_UDP GOST_RULES GOST_CHAINS GOST_EXTRA_ARGS GOST_CONFIG_TEMPLATE
	export REALITY_SHORT_IDS_JSON FIRST_SHORT_ID REALITY_SERVER_NAMES_JSON GOST_ARGS
}

install_base_packages() {
	detect_os
	need_iptables=""
	if [ "${HYSTERIA_ENABLE:-0}" = "1" ] && [ -n "${HYSTERIA_HOP_PORTS:-}" ]; then
		need_iptables="iptables:iptables"
	fi
	case "$OS_ID" in
		debian|ubuntu)
			missing=""
			for pkg_cmd in "curl:curl" "unzip:unzip" "openssl:openssl" "ca-certificates:update-ca-certificates" $need_iptables; do
				pkg="${pkg_cmd%%:*}"
				cmd="${pkg_cmd#*:}"
				command -v "$cmd" >/dev/null 2>&1 || missing="${missing} ${pkg}"
			done
			if [ -n "$missing" ]; then
				log "installing Debian/Ubuntu packages:${missing}"
				export DEBIAN_FRONTEND=noninteractive
				apt-get update -qq
				# shellcheck disable=SC2086
				apt-get install -y -qq --no-install-recommends $missing
			fi
			apt-get clean >/dev/null 2>&1 || true
			rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb 2>/dev/null || true
			;;
		alpine)
			missing=""
			for pkg_cmd in "curl:curl" "unzip:unzip" "openssl:openssl" "ca-certificates:update-ca-certificates" "iproute2-ss:ss" $need_iptables; do
				pkg="${pkg_cmd%%:*}"
				cmd="${pkg_cmd#*:}"
				command -v "$cmd" >/dev/null 2>&1 || missing="${missing} ${pkg}"
			done
			if [ -n "$missing" ]; then
				log "installing Alpine packages:${missing}"
				# shellcheck disable=SC2086
				apk add --no-cache $missing
			fi
			rm -rf /var/cache/apk/* 2>/dev/null || true
			;;
		*)
			die "unsupported OS_ID: ${OS_ID}"
			;;
	esac
}

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		openssl dgst -sha256 "$1" | awk '{print $NF}'
	fi
}

# download_verified <url> <dest> <checksum_url> <format: dgst|hashes|sums> <name-in-checksum-file>
# Verifies SHA-256 against the upstream release checksum file. A mismatch is fatal; a missing
# checksum file only warns unless SURGE_REQUIRE_CHECKSUM=1.
download_verified() {
	dv_url="$1"; dv_dest="$2"; dv_sumurl="$3"; dv_fmt="$4"; dv_name="$5"
	curl -fsSL --retry 3 --connect-timeout 10 -o "$dv_dest" "$dv_url" || die "download failed: ${dv_url}"
	dv_sums="${dv_dest}.sums"
	if ! curl -fsSL --retry 2 --connect-timeout 10 -o "$dv_sums" "$dv_sumurl" 2>/dev/null; then
		[ "${SURGE_REQUIRE_CHECKSUM:-0}" != "1" ] || die "checksum file unavailable: ${dv_sumurl}"
		warn "checksum file unavailable, skipping verification of ${dv_name}"
		return 0
	fi
	case "$dv_fmt" in
		dgst)   dv_want="$(awk '/^SHA2-256=/ {print $2}' "$dv_sums")" ;;
		hashes) dv_want="$(awk -v n="build/${dv_name}" '$2 == n {print $1}' "$dv_sums")" ;;
		*)      dv_want="$(awk -v n="${dv_name}" '$2 == n {print $1}' "$dv_sums")" ;;
	esac
	rm -f "$dv_sums"
	if [ -z "$dv_want" ]; then
		[ "${SURGE_REQUIRE_CHECKSUM:-0}" != "1" ] || die "no checksum entry for ${dv_name}"
		warn "no checksum entry for ${dv_name}, skipping verification"
		return 0
	fi
	dv_got="$(sha256_of "$dv_dest")"
	[ "$dv_got" = "$dv_want" ] || die "SHA-256 mismatch for ${dv_name}: expected ${dv_want}, got ${dv_got}"
	log "verified SHA-256 of ${dv_name}"
}

install_xray() {
	if [ "${XRAY_ENABLE:-1}" != "1" ]; then
		return 0
	fi
	want_ver="${XRAY_VERSION#v}"
	if [ -x /usr/local/bin/xray ]; then
		cur_ver="$(/usr/local/bin/xray version 2>/dev/null | awk 'NR==1 {print $2}' || true)"
		if [ "$cur_ver" = "$want_ver" ]; then
			log "xray v${want_ver} already installed"
			return 0
		fi
	fi

	log "downloading xray ${XRAY_VERSION} (linux-${XRAY_ARCH}, binary only to save disk/RAM) ..."
	tmp_dir="$(mktemp -d)"
	url="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-${XRAY_ARCH}.zip"
	download_verified "$url" "${tmp_dir}/xray.zip" "${url}.dgst" dgst "Xray-linux-${XRAY_ARCH}.zip"
	# Extract ONLY the xray executable (skip geoip.dat / geosite.dat ~30MB bloat)
	unzip -q -o "${tmp_dir}/xray.zip" xray -d "$tmp_dir"
	install -m 0755 "${tmp_dir}/xray" /usr/local/bin/xray
	rm -rf "$tmp_dir" /usr/local/share/xray 2>/dev/null || true
	log "installed $(/usr/local/bin/xray version | head -n 1)"
}

install_gost() {
	if [ "${GOST_ENABLE:-0}" != "1" ]; then
		return 0
	fi
	want_ver="${GOST_VERSION#v}"
	if [ -x /usr/local/bin/gost ]; then
		cur_ver="$(/usr/local/bin/gost -V 2>/dev/null | awk '{print $2}' | sed 's/^v//' || true)"
		if [ "$cur_ver" = "$want_ver" ]; then
			log "gost v${want_ver} already installed"
			return 0
		fi
	fi

	log "downloading gost ${GOST_VERSION} (linux_${GOST_ARCH}) ..."
	tmp_dir="$(mktemp -d)"
	url="https://github.com/go-gost/gost/releases/download/${GOST_VERSION}/gost_${want_ver}_linux_${GOST_ARCH}.tar.gz"
	download_verified "$url" "${tmp_dir}/gost.tar.gz" \
		"https://github.com/go-gost/gost/releases/download/${GOST_VERSION}/checksums.txt" sums "gost_${want_ver}_linux_${GOST_ARCH}.tar.gz"
	tar -xzf "${tmp_dir}/gost.tar.gz" -C "$tmp_dir" gost
	install -m 0755 "${tmp_dir}/gost" /usr/local/bin/gost
	rm -rf "$tmp_dir"
	log "installed $(/usr/local/bin/gost -V 2>/dev/null | head -n 1)"
}

install_hysteria() {
	if [ "${HYSTERIA_ENABLE:-0}" != "1" ]; then
		return 0
	fi
	want_ver="v${HYSTERIA_VERSION#v}"
	if [ -x /usr/local/bin/hysteria ]; then
		cur_ver="$(/usr/local/bin/hysteria version 2>/dev/null | awk '/^Version:/ {print $2}' || true)"
		if [ "$cur_ver" = "$want_ver" ]; then
			log "hysteria ${want_ver} already installed"
			return 0
		fi
	fi

	log "downloading hysteria ${want_ver} (linux-${HYSTERIA_ARCH}) ..."
	tmp_dir="$(mktemp -d)"
	url="https://github.com/apernet/hysteria/releases/download/app%2F${want_ver}/hysteria-linux-${HYSTERIA_ARCH}"
	download_verified "$url" "${tmp_dir}/hysteria" \
		"https://github.com/apernet/hysteria/releases/download/app%2F${want_ver}/hashes.txt" hashes "hysteria-linux-${HYSTERIA_ARCH}"
	install -m 0755 "${tmp_dir}/hysteria" /usr/local/bin/hysteria
	rm -rf "$tmp_dir"
	log "installed hysteria $(/usr/local/bin/hysteria version 2>/dev/null | awk '/^Version:/ {print $2}')"
}

ensure_secrets() {
	if [ "${XRAY_ENABLE:-1}" != "1" ] && [ "${HYSTERIA_ENABLE:-0}" != "1" ]; then
		return 0
	fi
	if [ -f "$SECRETS_ENV" ]; then
		# shellcheck disable=SC1090
		. "$SECRETS_ENV"
	else
		umask 077
		printf '# surge node secrets — generated %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$SECRETS_ENV"
		chmod 600 "$SECRETS_ENV"
	fi

	changed=0
	if [ "${XRAY_ENABLE:-1}" = "1" ]; then
		if [ -z "${VLESS_UUID:-}" ]; then
			VLESS_UUID="$(/usr/local/bin/xray uuid)"
			upsert_env_var VLESS_UUID "$VLESS_UUID"
			changed=1
		fi

		if [ -z "${REALITY_PRIVATE_KEY:-}" ] || [ -z "${REALITY_PUBLIC_KEY:-}" ]; then
			key_out="$(/usr/local/bin/xray x25519)"
			REALITY_PRIVATE_KEY="$(printf '%s\n' "$key_out" | awk -F': ' '/Private[Kk]ey|Private key/ {print $2}' | tr -d '[:space:]')"
			REALITY_PUBLIC_KEY="$(printf '%s\n' "$key_out" | awk -F': ' '/Public[Kk]ey|Public key|Password/ {print $2}' | tr -d '[:space:]')"
			[ -n "$REALITY_PRIVATE_KEY" ] && [ -n "$REALITY_PUBLIC_KEY" ] || die "failed to parse xray x25519 output"
			upsert_env_var REALITY_PRIVATE_KEY "$REALITY_PRIVATE_KEY"
			upsert_env_var REALITY_PUBLIC_KEY "$REALITY_PUBLIC_KEY"
			changed=1
		fi
	fi

	if [ "${HYSTERIA_ENABLE:-0}" = "1" ]; then
		if [ -z "${HYSTERIA_PASSWORD:-}" ]; then
			HYSTERIA_PASSWORD="$(openssl rand -hex 16)"
			upsert_env_var HYSTERIA_PASSWORD "$HYSTERIA_PASSWORD"
			changed=1
		fi
	fi

	# Persist ad-hoc node overrides if no nodes/<node>.env profile exists
	if [ ! -f "${SURGE_ROOT}/nodes/${NODE_NAME}.env" ] && ! grep -q '^NODE_NAME=' "$SECRETS_ENV" 2>/dev/null; then
		upsert_env_var NODE_NAME "$NODE_NAME"
		upsert_env_var NODE_HOST "$NODE_HOST"
		upsert_env_var PUBLIC_VLESS_PORT "$PUBLIC_VLESS_PORT"
		upsert_env_var VLESS_LISTEN_PORT "$VLESS_LISTEN_PORT"
		upsert_env_var HYSTERIA_ENABLE "$HYSTERIA_ENABLE"
		upsert_env_var PUBLIC_HYSTERIA_PORT "$PUBLIC_HYSTERIA_PORT"
		upsert_env_var HYSTERIA_LISTEN_PORT "$HYSTERIA_LISTEN_PORT"
		upsert_env_var GOST_ENABLE "$GOST_ENABLE"
		changed=1
	fi

	if [ "$changed" -eq 1 ]; then
		log "updated secrets in ${SECRETS_ENV}"
	else
		log "keeping existing secrets in ${SECRETS_ENV}"
	fi

	export VLESS_UUID REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY HYSTERIA_PASSWORD
}

upsert_env_var() {
	key="$1"
	val="$2"
	touch "$SECRETS_ENV"
	chmod 600 "$SECRETS_ENV"
	grep -v "^${key}=" "$SECRETS_ENV" > "${SECRETS_ENV}.tmp" || true
	escaped_val="$(printf '%s' "$val" | sed "s/'/'\\\\''/g")"
	printf "%s='%s'\n" "$key" "$escaped_val" >> "${SECRETS_ENV}.tmp"
	mv "${SECRETS_ENV}.tmp" "$SECRETS_ENV"
	chmod 600 "$SECRETS_ENV"
}

remove_env_var() {
	key="$1"
	[ -f "$SECRETS_ENV" ] || return 0
	grep -v "^${key}=" "$SECRETS_ENV" > "${SECRETS_ENV}.tmp" || true
	mv "${SECRETS_ENV}.tmp" "$SECRETS_ENV"
	chmod 600 "$SECRETS_ENV"
}

persist_cli_overrides() {
	[ -n "${_cli_XRAY_ENABLE:-}" ] && upsert_env_var XRAY_ENABLE "$_cli_XRAY_ENABLE"
	[ -n "${_cli_PUBLIC_VLESS_PORT:-}" ] && upsert_env_var PUBLIC_VLESS_PORT "$_cli_PUBLIC_VLESS_PORT"
	[ -n "${_cli_VLESS_LISTEN_PORT:-}" ] && upsert_env_var VLESS_LISTEN_PORT "$_cli_VLESS_LISTEN_PORT"
	[ -n "${_cli_HYSTERIA_ENABLE:-}" ] && upsert_env_var HYSTERIA_ENABLE "$_cli_HYSTERIA_ENABLE"
	[ -n "${_cli_PUBLIC_HYSTERIA_PORT:-}" ] && upsert_env_var PUBLIC_HYSTERIA_PORT "$_cli_PUBLIC_HYSTERIA_PORT"
	[ -n "${_cli_HYSTERIA_LISTEN_PORT:-}" ] && upsert_env_var HYSTERIA_LISTEN_PORT "$_cli_HYSTERIA_LISTEN_PORT"
	[ -n "${_cli_HYSTERIA_HOP_PORTS:-}" ] && upsert_env_var HYSTERIA_HOP_PORTS "$_cli_HYSTERIA_HOP_PORTS"
	[ -n "${_cli_HYSTERIA_HOP_INTERVAL:-}" ] && upsert_env_var HYSTERIA_HOP_INTERVAL "$_cli_HYSTERIA_HOP_INTERVAL"
	[ -n "${_cli_HYSTERIA_SNI:-}" ] && upsert_env_var HYSTERIA_SNI "$_cli_HYSTERIA_SNI"
	[ -n "${_cli_HYSTERIA_CF_DNS_TOKEN:-}" ] && upsert_env_var HYSTERIA_CF_DNS_TOKEN "$_cli_HYSTERIA_CF_DNS_TOKEN"
	[ -n "${_cli_GOST_ENABLE:-}" ] && upsert_env_var GOST_ENABLE "$_cli_GOST_ENABLE"
	[ -n "${_cli_GOST_LISTEN_PORT:-}" ] && upsert_env_var GOST_LISTEN_PORT "$_cli_GOST_LISTEN_PORT"
	[ -n "${_cli_GOST_FORWARD_TCP:-}" ] && upsert_env_var GOST_FORWARD_TCP "$_cli_GOST_FORWARD_TCP"
	[ -n "${_cli_GOST_FORWARD_UDP:-}" ] && upsert_env_var GOST_FORWARD_UDP "$_cli_GOST_FORWARD_UDP"
	[ -n "${_cli_GOST_RULES:-}" ] && upsert_env_var GOST_RULES "$_cli_GOST_RULES"
	[ -n "${_cli_GOST_CHAINS:-}" ] && upsert_env_var GOST_CHAINS "$_cli_GOST_CHAINS"
	[ -n "${_cli_GOST_EXTRA_ARGS:-}" ] && upsert_env_var GOST_EXTRA_ARGS "$_cli_GOST_EXTRA_ARGS"
	[ -n "${_cli_GOST_CONFIG_TEMPLATE:-}" ] && upsert_env_var GOST_CONFIG_TEMPLATE "$_cli_GOST_CONFIG_TEMPLATE"
	return 0
}

escape_sed() {
	printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}

render_template() {
	src="$1"
	dst="$2"
	mkdir -p "$(dirname "$dst")"
	sed \
		-e "s|\${SURGE_ROOT}|$(escape_sed "${SURGE_ROOT}")|g" \
		-e "s|\${VLESS_LISTEN_PORT}|$(escape_sed "${VLESS_LISTEN_PORT}")|g" \
		-e "s|\${VLESS_UUID}|$(escape_sed "${VLESS_UUID:-}")|g" \
		-e "s|\${VLESS_EMAIL}|$(escape_sed "${VLESS_EMAIL}")|g" \
		-e "s|\${REALITY_DEST}|$(escape_sed "${REALITY_DEST}")|g" \
		-e "s|\${REALITY_SNI}|$(escape_sed "${REALITY_SNI}")|g" \
		-e "s|\${REALITY_SERVER_NAMES_JSON}|$(escape_sed "${REALITY_SERVER_NAMES_JSON}")|g" \
		-e "s|\${REALITY_PRIVATE_KEY}|$(escape_sed "${REALITY_PRIVATE_KEY:-}")|g" \
		-e "s|\${REALITY_PUBLIC_KEY}|$(escape_sed "${REALITY_PUBLIC_KEY:-}")|g" \
		-e "s|\${REALITY_MIN_CLIENT_VER}|$(escape_sed "${REALITY_MIN_CLIENT_VER}")|g" \
		-e "s|\${REALITY_MAX_TIME_DIFF}|$(escape_sed "${REALITY_MAX_TIME_DIFF}")|g" \
		-e "s|\${REALITY_SHORT_IDS_JSON}|$(escape_sed "${REALITY_SHORT_IDS_JSON}")|g" \
		-e "s|\${BLOCKED_IPS_JSON}|$(escape_sed "${BLOCKED_IPS_JSON}")|g" \
		-e "s|\${BLOCKED_UDP_RULE}|$(escape_sed "${BLOCKED_UDP_RULE:-}")|g" \
		-e "s|\${TCP_KEEPALIVE_IDLE}|$(escape_sed "${TCP_KEEPALIVE_IDLE}")|g" \
		-e "s|\${TCP_KEEPALIVE_INTERVAL}|$(escape_sed "${TCP_KEEPALIVE_INTERVAL}")|g" \
		-e "s|\${TCP_USER_TIMEOUT}|$(escape_sed "${TCP_USER_TIMEOUT}")|g" \
		-e "s|\${GOGC}|$(escape_sed "${GOGC}")|g" \
		-e "s|\${GOMAXPROCS}|$(escape_sed "${GOMAXPROCS}")|g" \
		-e "s|\${XRAY_GOMEMLIMIT}|$(escape_sed "${XRAY_GOMEMLIMIT}")|g" \
		-e "s|\${HYSTERIA_GOMEMLIMIT}|$(escape_sed "${HYSTERIA_GOMEMLIMIT}")|g" \
		-e "s|\${GOST_GOMEMLIMIT}|$(escape_sed "${GOST_GOMEMLIMIT}")|g" \
		-e "s|\${GOST_LISTEN_PORT}|$(escape_sed "${GOST_LISTEN_PORT}")|g" \
		-e "s|\${GOST_FORWARD_TCP}|$(escape_sed "${GOST_FORWARD_TCP:-}")|g" \
		-e "s|\${GOST_FORWARD_UDP}|$(escape_sed "${GOST_FORWARD_UDP:-}")|g" \
		-e "s|\${GOST_LOG_LEVEL}|$(escape_sed "${GOST_LOG_LEVEL:-warn}")|g" \
		-e "s|\${GOST_ARGS}|$(escape_sed "${GOST_ARGS}")|g" \
		"$src" > "$dst"
}

render_hysteria_config() {
	mkdir -p /etc/hysteria
	chmod 0700 /etc/hysteria
	if [ -n "${HYSTERIA_CF_DNS_TOKEN:-}" ]; then
		mkdir -p /etc/hysteria/acme
		chmod 0700 /etc/hysteria/acme
		cat > /etc/hysteria/config.yaml <<EOF
listen: :${HYSTERIA_LISTEN_PORT}

acme:
  domains:
    - ${HYSTERIA_SNI}
  email: ${HYSTERIA_ACME_EMAIL}
  type: dns
  dns:
    name: cloudflare
    config:
      cloudflare_api_token: ${HYSTERIA_CF_DNS_TOKEN}
  dir: /etc/hysteria/acme
EOF
	else
		if [ ! -s /etc/hysteria/cert.pem ] || [ ! -s /etc/hysteria/key.pem ]; then
			log "generating self-signed ECDSA P-256 certificate for ${HYSTERIA_SNI}"
			openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
				-days 3650 -subj "/CN=${HYSTERIA_SNI}" \
				-addext "subjectAltName=DNS:${HYSTERIA_SNI}" \
				-keyout /etc/hysteria/key.pem -out /etc/hysteria/cert.pem >/dev/null 2>&1
			chmod 0600 /etc/hysteria/key.pem /etc/hysteria/cert.pem
		fi
		cat > /etc/hysteria/config.yaml <<EOF
listen: :${HYSTERIA_LISTEN_PORT}

tls:
  cert: /etc/hysteria/cert.pem
  key: /etc/hysteria/key.pem
EOF
	fi

	cat >> /etc/hysteria/config.yaml <<EOF

quic:
  initStreamReceiveWindow: ${HYSTERIA_INIT_STREAM_WIN}
  maxStreamReceiveWindow: ${HYSTERIA_MAX_STREAM_WIN}
  initConnReceiveWindow: ${HYSTERIA_INIT_CONN_WIN}
  maxConnReceiveWindow: ${HYSTERIA_MAX_CONN_WIN}
  maxIdleTimeout: 30s
  maxIncomingStreams: ${HYSTERIA_MAX_STREAMS}
  disablePathMTUDiscovery: false

auth:
  type: password
  password: "${HYSTERIA_PASSWORD}"

ignoreClientBandwidth: false

masquerade:
  type: proxy
  proxy:
    url: ${HYSTERIA_MASQUERADE_URL}
    rewriteHost: true
EOF
	chmod 0600 /etc/hysteria/config.yaml
}

validate_hysteria_hop_ports() {
	[ -n "${HYSTERIA_HOP_PORTS:-}" ] || return 0
	for item in $(printf '%s' "$HYSTERIA_HOP_PORTS" | tr ',' ' '); do
		case "$item" in
			''|*[!0-9-]*|-*|*-|*-*-*) die "invalid HYSTERIA_HOP_PORTS entry '${item}' (expected N or N-M)" ;;
		esac
		hp_lo="${item%%-*}"
		hp_hi="${item##*-}"
		if [ "$hp_lo" -lt 1 ] || [ "$hp_hi" -gt 65535 ] || [ "$hp_lo" -gt "$hp_hi" ]; then
			die "invalid HYSTERIA_HOP_PORTS range '${item}' (must satisfy 1 <= start <= end <= 65535)"
		fi
	done
}

clear_hysteria_port_hop() {
	for ipt in iptables ip6tables; do
		command -v "$ipt" >/dev/null 2>&1 || continue
		"$ipt" -t nat -S PREROUTING 2>/dev/null | grep -- 'surge-hy2-hop' | while IFS= read -r rule; do
			del_rule="$(printf '%s' "$rule" | sed 's/^-A /-D /')"
			# shellcheck disable=SC2086
			"$ipt" -t nat $del_rule >/dev/null 2>&1 || true
		done
	done
}

# Desired iptables-save style rule lines, one per hop range (sorted for comparison).
hysteria_port_hop_desired() {
	for item in $(printf '%s' "$HYSTERIA_HOP_PORTS" | tr ',' ' '); do
		[ -n "$item" ] || continue
		printf -- '-A PREROUTING -p udp -m udp --dport %s -m comment --comment surge-hy2-hop -j REDIRECT --to-ports %s\n' \
			"$(printf '%s' "$item" | tr '-' ':')" "${HYSTERIA_LISTEN_PORT}"
	done | sort
}

# True when the installed surge-hy2-hop rules exactly match the desired set (no stale/missing rules).
hysteria_port_hop_active() {
	if [ "${HYSTERIA_ENABLE:-0}" != "1" ] || [ -z "${HYSTERIA_HOP_PORTS:-}" ]; then
		return 0
	fi
	command -v iptables >/dev/null 2>&1 || return 1
	have="$(iptables -t nat -S PREROUTING 2>/dev/null | grep -- 'surge-hy2-hop' | sort || true)"
	want="$(hysteria_port_hop_desired)"
	[ "$have" = "$want" ]
}

# Idempotent: leaves matching rules untouched (no traffic gap); otherwise rebuilds the rule set.
# Never fatal to the caller: hop is an optimisation, the primary Hysteria2 port must stay usable.
reconcile_hysteria_port_hop() {
	if [ "${HYSTERIA_ENABLE:-0}" != "1" ] || [ -z "${HYSTERIA_HOP_PORTS:-}" ]; then
		clear_hysteria_port_hop
		return 0
	fi
	if ! command -v iptables >/dev/null 2>&1; then
		warn "iptables is required for HYSTERIA_HOP_PORTS; port hopping disabled"
		return 1
	fi
	if hysteria_port_hop_active; then
		return 0
	fi
	clear_hysteria_port_hop
	for item in $(printf '%s' "$HYSTERIA_HOP_PORTS" | tr ',' ' '); do
		[ -n "$item" ] || continue
		dport_spec="$(printf '%s' "$item" | tr '-' ':')"
		if ! iptables -t nat -A PREROUTING -p udp -m udp --dport "$dport_spec" \
			-m comment --comment surge-hy2-hop -j REDIRECT --to-ports "${HYSTERIA_LISTEN_PORT}"; then
			warn "failed to install hop rule for udp ${dport_spec} (kernel nat/REDIRECT support missing?)"
			return 1
		fi
		if command -v ip6tables >/dev/null 2>&1; then
			ip6tables -t nat -A PREROUTING -p udp -m udp --dport "$dport_spec" \
				-m comment --comment surge-hy2-hop -j REDIRECT --to-ports "${HYSTERIA_LISTEN_PORT}" >/dev/null 2>&1 || true
		fi
	done
	log "hysteria port hop active: udp ${HYSTERIA_HOP_PORTS} -> :${HYSTERIA_LISTEN_PORT}"
}

render_gost_config() {
	mkdir -p /etc/gost
	if [ -n "${GOST_CONFIG_TEMPLATE:-}" ]; then
		tpl_path="$GOST_CONFIG_TEMPLATE"
		case "$tpl_path" in
			/*) ;;
			*)  tpl_path="${SURGE_ROOT}/${tpl_path}" ;;
		esac
		[ -f "$tpl_path" ] || die "GOST_CONFIG_TEMPLATE not found: ${tpl_path}"
		render_template "$tpl_path" /etc/gost/config.json
		/usr/local/bin/gost -C /etc/gost/config.json -O json >/dev/null
		chmod 0600 /etc/gost/config.json
		return 0
	fi

	set -- -C "{\"log\":{\"level\":\"${GOST_LOG_LEVEL:-warn}\",\"output\":\"stderr\"}}"
	if [ -n "${GOST_FORWARD_TCP:-}" ]; then
		for item in $(printf '%s' "$GOST_FORWARD_TCP" | tr ',' ' '); do
			case "$item" in
				*/*) lport="${item%%/*}"; target="${item#*/}" ;;
				*)   lport="${GOST_LISTEN_PORT}"; target="$item" ;;
			esac
			set -- "$@" -L "tcp://:${lport}/${target}?keepAlive=true&ttl=300s&nodelay=true"
		done
	fi
	if [ -n "${GOST_FORWARD_UDP:-}" ]; then
		for item in $(printf '%s' "$GOST_FORWARD_UDP" | tr ',' ' '); do
			case "$item" in
				*/*) lport="${item%%/*}"; target="${item#*/}" ;;
				*)   lport="${GOST_LISTEN_PORT}"; target="$item" ;;
			esac
			set -- "$@" -L "udp://:${lport}/${target}?keepAlive=true&ttl=60s"
		done
	fi
	if [ -n "${GOST_RULES:-}" ]; then
		# shellcheck disable=SC2086
		set -- "$@" $GOST_RULES
	fi
	if [ -n "${GOST_CHAINS:-}" ]; then
		# shellcheck disable=SC2086
		set -- "$@" $GOST_CHAINS
	fi
	if [ -n "${GOST_EXTRA_ARGS:-}" ]; then
		# shellcheck disable=SC2086
		set -- "$@" $GOST_EXTRA_ARGS
	fi
	if [ "$#" -le 2 ]; then
		die "GOST_ENABLE=1 requires GOST_FORWARD_TCP, GOST_FORWARD_UDP, GOST_RULES, or GOST_CONFIG_TEMPLATE"
	fi
	/usr/local/bin/gost "$@" -O json > /etc/gost/config.json
	chmod 0600 /etc/gost/config.json
}

gost_tcp_ports() {
	if [ -f /etc/gost/config.json ]; then
		ports="$(awk -F'"' '/"addr":/ {
			addr=$4
			if (addr ~ /^(:|0\.0\.0\.0:|127\.0\.0\.1:|\[::\]:)[0-9]+$/) {
				sub(/^.*:/, "", addr)
				print addr
			}
		}' /etc/gost/config.json | sort -u | tr '\n' ' ')"
		if [ -n "$ports" ]; then
			printf '%s' "$ports"
			return 0
		fi
	fi
	printf '%s' "${GOST_LISTEN_PORT}"
}

resolve_ipv4_dns() {
	host="$1"
	case "$host" in
		''|*[!0-9.]*) ;;
		*) printf '%s' "$host"; return 0 ;;
	esac
	ip=""
	if command -v dig >/dev/null 2>&1; then
		ip="$(dig +short +time=2 +tries=1 A "$host" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1 || true)"
	fi
	if [ -z "$ip" ] && command -v resolvectl >/dev/null 2>&1; then
		ip="$(resolvectl query -4 --legend=no "$host" 2>/dev/null | awk 'NR==1 {for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {print $i; exit}}' || true)"
	fi
	if [ -z "$ip" ] && command -v nslookup >/dev/null 2>&1; then
		ip="$(nslookup -type=a "$host" 2>/dev/null | awk '/^Address:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $2; exit}' || true)"
	fi
	if [ -z "$ip" ] && command -v getent >/dev/null 2>&1; then
		ip="$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1 {print $1}' || true)"
	fi
	printf '%s' "$ip"
}

refresh_hosts_cache() {
	[ -w /etc/hosts ] || return 0
	hosts_to_pin=""
	if [ "${XRAY_ENABLE:-1}" = "1" ]; then
		hosts_to_pin="${REALITY_DEST%:*}"
	fi

	if [ "${GOST_ENABLE:-0}" = "1" ]; then
		for item in $(printf '%s %s' "${GOST_FORWARD_TCP:-}" "${GOST_FORWARD_UDP:-}" | tr ',' ' '); do
			target="${item#*/}"
			thost="${target%:*}"
			if [ -n "$thost" ]; then
				case " $hosts_to_pin " in
					*" $thost "*) ;;
					*) hosts_to_pin="${hosts_to_pin:+$hosts_to_pin }${thost}" ;;
				esac
			fi
		done
		if [ -f /etc/gost/config.json ]; then
			for thost in $(awk -F'"' '/"addr":/ {
				a=$4
				sub(/:[0-9]+$/, "", a)
				if (a ~ /^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/) print a
			}' /etc/gost/config.json); do
				case " $hosts_to_pin " in
					*" $thost "*) ;;
					*) hosts_to_pin="${hosts_to_pin:+$hosts_to_pin }${thost}" ;;
				esac
			done
		fi
	fi

	[ -n "$hosts_to_pin" ] || return 0

	entries=""
	for h in $hosts_to_pin; do
		hip="$(resolve_ipv4_dns "$h")"
		if [ -n "$hip" ]; then
			entries="${entries:+${entries}
}${hip} ${h}"
		fi
	done

	[ -n "$entries" ] || return 0

	want_block="# BEGIN SURGE HOSTS
${entries}
# END SURGE HOSTS"

	cur_block="$(awk '/^# BEGIN SURGE HOSTS$/{flag=1} flag{print} /^# END SURGE HOSTS$/{flag=0}' /etc/hosts 2>/dev/null || true)"
	if [ "$cur_block" = "$want_block" ]; then
		return 0
	fi

	tmp_hosts="$(mktemp)"
	awk '/^# BEGIN SURGE HOSTS$/{skip=1; next} /^# END SURGE HOSTS$/{skip=0; next} !skip{print}' /etc/hosts > "$tmp_hosts"
	printf '%s\n' "$want_block" >> "$tmp_hosts"
	cat "$tmp_hosts" > /etc/hosts
	rm -f "$tmp_hosts"
}

tune_os() {
	detect_os
	detect_resources

	# Determine max TCP socket buffer based on available RAM to prevent cgroup socket throttling
	if [ "$MEM_MB" -le 512 ]; then
		tcp_buf_max="4194304"
	elif [ "$MEM_MB" -le 1024 ]; then
		tcp_buf_max="16777216"
	else
		tcp_buf_max="67108864"
	fi

	# Probe and persist BBR + TCP socket tuning to /etc/sysctl.d/99-bbr.conf
	mkdir -p /etc/sysctl.d
	rm -f /etc/sysctl.d/99-surge.conf 2>/dev/null || true
	: > /etc/sysctl.d/99-bbr.conf
	while IFS='=' read -r k v; do
		[ -n "$k" ] || continue
		proc_path="/proc/sys/$(printf '%s' "$k" | tr '.' '/')"
		[ -e "$proc_path" ] || continue
		if sys_out="$(sysctl -w "${k}=${v}" 2>&1)" && ! printf '%s' "$sys_out" | grep -qiE 'error|cannot|denied|permitted|invalid|read-only|unknown'; then
			printf '%s=%s\n' "$k" "$v" >> /etc/sysctl.d/99-bbr.conf
		fi
	done <<EOF
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq
net.ipv4.tcp_fastopen=3
net.core.rmem_max=${tcp_buf_max}
net.core.wmem_max=${tcp_buf_max}
net.ipv4.tcp_rmem=4096 87380 ${tcp_buf_max}
net.ipv4.tcp_wmem=4096 65536 ${tcp_buf_max}
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_dsack=1
net.ipv4.tcp_timestamps=0
net.ipv4.tcp_rfc1337=1
net.ipv4.tcp_synack_retries=2
net.ipv4.tcp_syn_retries=3
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.tcp_ecn=0
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_tw_reuse=0
net.ipv4.tcp_fin_timeout=10
net.ipv4.tcp_orphan_retries=2
net.ipv4.tcp_retries2=8
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=15
net.ipv4.tcp_keepalive_probes=4
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.ip_local_port_range=10240 65535
net.ipv4.udp_rmem_min=16384
net.ipv4.udp_wmem_min=16384
net.core.netdev_max_backlog=10000
net.core.somaxconn=4096
EOF

	if [ "$INIT_SYSTEM" = "systemd" ]; then
		# On small Debian/Ubuntu LXC containers, disable resource-heavy background daemons
		if [ "${MEM_MB:-1024}" -le 512 ]; then
			systemctl stop systemd-resolved 2>/dev/null || true
			systemctl disable systemd-resolved 2>/dev/null || true
			systemctl mask systemd-resolved 2>/dev/null || true
			systemctl stop polkit 2>/dev/null || true
			systemctl disable polkit 2>/dev/null || true
			systemctl mask polkit 2>/dev/null || true
			rm -f /etc/resolv.conf
			cat > /etc/resolv.conf <<'EOF_RESOLV'
nameserver 10.88.0.1
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF_RESOLV
		fi
		# Cap journald disk usage to 16M on small Debian/Ubuntu containers
		mkdir -p /etc/systemd/journald.conf.d
		cat > /etc/systemd/journald.conf.d/99-surge.conf <<'EOF'
[Journal]
SystemMaxUse=16M
RuntimeMaxUse=8M
MaxFileSec=3day
EOF
		systemctl restart systemd-journald >/dev/null 2>&1 || true
		journalctl --vacuum-size=4M >/dev/null 2>&1 || true
	elif [ "$INIT_SYSTEM" = "openrc" ]; then
		rc-update add sysctl boot >/dev/null 2>&1 || true
		rc-update add crond default >/dev/null 2>&1 || true
		rc-service crond start >/dev/null 2>&1 || true
	fi
}

configure_firewall() {
	if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
		if [ "${XRAY_ENABLE:-1}" = "1" ]; then
			ufw allow "${VLESS_LISTEN_PORT}/tcp" comment "surge vless (${NODE_NAME})" >/dev/null 2>&1 || true
		fi
		if [ "${HYSTERIA_ENABLE:-0}" = "1" ]; then
			ufw allow "${HYSTERIA_LISTEN_PORT}/udp" comment "surge hysteria2 (${NODE_NAME})" >/dev/null 2>&1 || true
			if [ -n "${HYSTERIA_HOP_PORTS:-}" ]; then
				for item in $(printf '%s' "$HYSTERIA_HOP_PORTS" | tr ',' ' '); do
					ufw_spec="$(printf '%s' "$item" | tr '-' ':')"
					ufw allow "${ufw_spec}/udp" comment "surge hysteria2 hop (${NODE_NAME})" >/dev/null 2>&1 || true
				done
			fi
		fi
		if [ "${GOST_ENABLE:-0}" = "1" ]; then
			for p in $(gost_tcp_ports); do
				ufw allow "${p}/tcp" comment "surge gost tcp (${NODE_NAME})" >/dev/null 2>&1 || true
				[ -n "${GOST_FORWARD_UDP:-}" ] && ufw allow "${p}/udp" comment "surge gost udp (${NODE_NAME})" >/dev/null 2>&1 || true
			done
		fi
		log "ensured ufw rules for surge (${NODE_NAME})"
	fi
}

cleanup_legacy_services() {
	# Remove unused hysteria test artifacts when CLEANUP_LEGACY_HYSTERIA=1 and HYSTERIA_ENABLE=0 (frees ~24MB binary + RAM)
	if [ "${CLEANUP_LEGACY_HYSTERIA:-0}" = "1" ] && [ "${HYSTERIA_ENABLE:-0}" != "1" ]; then
		if [ "$INIT_SYSTEM" = "openrc" ] && [ -f /etc/init.d/hysteria ]; then
			log "stopping and removing legacy hysteria service on ${NODE_NAME}"
			rc-service hysteria stop >/dev/null 2>&1 || true
			rc-update del hysteria default >/dev/null 2>&1 || true
			rm -f /etc/init.d/hysteria /usr/local/bin/hysteria /var/log/hysteria.log
			rm -rf /etc/hysteria
		elif [ "$INIT_SYSTEM" = "systemd" ]; then
			for unit in hysteria hysteria2; do
				if [ -f "/etc/systemd/system/${unit}.service" ]; then
					systemctl disable --now "$unit" >/dev/null 2>&1 || true
					rm -f "/etc/systemd/system/${unit}.service"
				fi
			done
			rm -f /usr/local/bin/hysteria
			rm -rf /etc/hysteria
			systemctl daemon-reload >/dev/null 2>&1 || true
		fi
	fi
}

port_is_listening() {
	proto="$1"
	port="$2"
	if command -v ss >/dev/null 2>&1; then
		case "$proto" in
			tcp) ss -tln | grep -Eq ":${port}[[:space:]]" ;;
			udp) ss -uln | grep -Eq ":${port}[[:space:]]" ;;
			*)   return 1 ;;
		esac
	else
		netstat -tuln 2>/dev/null | grep -E "^${proto}" | grep -Eq ":${port}[[:space:]]"
	fi
}

svc_is_active() {
	svc="$1"
	if [ "$INIT_SYSTEM" = "systemd" ]; then
		systemctl is-active --quiet "$svc"
	else
		rc-service "$svc" status >/dev/null 2>&1
	fi
}

svc_is_enabled() {
	svc="$1"
	if [ "$INIT_SYSTEM" = "systemd" ]; then
		systemctl is-enabled --quiet "$svc" 2>/dev/null
	else
		rc-update show default 2>/dev/null | grep -Eq "[[:space:]]${svc}[[:space:]]"
	fi
}

svc_restart() {
	svc="$1"
	if [ "$INIT_SYSTEM" = "systemd" ]; then
		systemctl restart "$svc"
	else
		if ! rc-service "$svc" status >/dev/null 2>&1; then
			rc-service "$svc" zap >/dev/null 2>&1 || true
		fi
		rc-service "$svc" restart
	fi
}

svc_stop() {
	svc="$1"
	if [ "$INIT_SYSTEM" = "systemd" ]; then
		systemctl stop "$svc" >/dev/null 2>&1 || true
	else
		rc-service "$svc" stop >/dev/null 2>&1 || true
	fi
}

svc_enable_and_restart() {
	svc="$1"
	if [ "$INIT_SYSTEM" = "systemd" ]; then
		systemctl daemon-reload
		systemctl enable "$svc" >/dev/null 2>&1
		systemctl restart "$svc"
	else
		chmod 0755 "/etc/init.d/${svc}"
		rc-update add "$svc" default >/dev/null 2>&1 || true
		if ! rc-service "$svc" status >/dev/null 2>&1; then
			rc-service "$svc" zap >/dev/null 2>&1 || true
		fi
		rc-service "$svc" restart
	fi
}

svc_disable_and_stop() {
	svc="$1"
	if [ "$INIT_SYSTEM" = "systemd" ]; then
		systemctl disable --now "$svc" >/dev/null 2>&1 || true
		rm -f "/etc/systemd/system/${svc}.service"
		systemctl daemon-reload >/dev/null 2>&1 || true
	else
		rc-service "$svc" stop >/dev/null 2>&1 || true
		rc-update del "$svc" default >/dev/null 2>&1 || true
		rm -f "/etc/init.d/${svc}"
	fi
}

install_watchdog() {
	if [ "$INIT_SYSTEM" = "systemd" ]; then
		rm -f /etc/cron.d/surge-watchdog 2>/dev/null || true
		cat > /etc/systemd/system/surge-watchdog.service <<EOF
[Unit]
Description=Surge Service and Hosts Cache Watchdog
After=network.target

[Service]
Type=oneshot
ExecStart=${SURGE_ROOT}/scripts/watchdog.sh
EOF
		cat > /etc/systemd/system/surge-watchdog.timer <<'EOF'
[Unit]
Description=Run Surge Watchdog every 2 minutes

[Timer]
OnBootSec=15s
OnUnitActiveSec=2min
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
		systemctl daemon-reload
		systemctl enable --now surge-watchdog.timer >/dev/null 2>&1
	elif [ -d /etc/crontabs ]; then
		touch /etc/crontabs/root
		grep -v "${SURGE_ROOT}/scripts/watchdog.sh" /etc/crontabs/root > /etc/crontabs/root.tmp || true
		printf '@reboot %s/scripts/watchdog.sh >/dev/null 2>&1\n' "${SURGE_ROOT}" >> /etc/crontabs/root.tmp
		printf '*/2 * * * * %s/scripts/watchdog.sh >/dev/null 2>&1\n' "${SURGE_ROOT}" >> /etc/crontabs/root.tmp
		mv /etc/crontabs/root.tmp /etc/crontabs/root
		chmod 0600 /etc/crontabs/root
	fi
}

watchdog_status() {
	if [ "$INIT_SYSTEM" = "systemd" ]; then
		if systemctl is-active --quiet surge-watchdog.timer 2>/dev/null; then
			printf 'active (systemd-timer: surge-watchdog.timer)'
		else
			printf 'inactive (systemd-timer)'
		fi
	else
		if rc-service crond status >/dev/null 2>&1 && grep -q "${SURGE_ROOT}/scripts/watchdog.sh" /etc/crontabs/root 2>/dev/null; then
			printf 'active (openrc-crond: */2 * * * *)'
		else
			printf 'inactive (openrc-crond)'
		fi
	fi
}

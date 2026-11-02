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
			;;
		aarch64|arm64)
			XRAY_ARCH="arm64-v8a"
			GOST_ARCH="arm64"
			;;
		*)
			die "unsupported CPU architecture: ${ARCH_RAW}"
			;;
	esac

	export OS_ID OS_PRETTY INIT_SYSTEM ARCH_RAW XRAY_ARCH GOST_ARCH
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

	if [ "$MEM_MB" -le 512 ]; then
		GOGC="50"
		GOMAXPROCS="1"
		XRAY_GOMEMLIMIT="48MiB"
		GOST_GOMEMLIMIT="24MiB"
	else
		GOGC="75"
		GOMAXPROCS="2"
		XRAY_GOMEMLIMIT="128MiB"
		GOST_GOMEMLIMIT="48MiB"
	fi

	export MEM_MB DISK_AVAIL_MB GOGC GOMAXPROCS XRAY_GOMEMLIMIT GOST_GOMEMLIMIT
}

load_env() {
	arg_node="${1:-}"
	if [ -n "$arg_node" ]; then
		if [ -f "${SURGE_ROOT}/nodes/${arg_node}.env" ]; then
			printf '%s\n' "$arg_node" > "$NODE_FILE"
		else
			die "node profile nodes/${arg_node}.env not found"
		fi
	fi

	[ -f "$CONFIG_ENV" ] || die "missing ${CONFIG_ENV}"
	set -a
	# shellcheck disable=SC1090
	. "$CONFIG_ENV"
	if [ -f "$NODE_FILE" ]; then
		selected_node="$(tr -d '[:space:]' < "$NODE_FILE")"
		if [ -n "$selected_node" ] && [ -f "${SURGE_ROOT}/nodes/${selected_node}.env" ]; then
			# shellcheck disable=SC1090
			. "${SURGE_ROOT}/nodes/${selected_node}.env"
		fi
	fi
	if [ -f "$SECRETS_ENV" ]; then
		# shellcheck disable=SC1090
		. "$SECRETS_ENV"
	fi
	set +a

	# Format shortIds JSON array and first shortId
	REALITY_SHORT_IDS_JSON="$(printf '%s' "${REALITY_SHORT_IDS}" | awk -F',' '{
		printf "["
		for (i=1; i<=NF; i++) {
			gsub(/^[ \t]+|[ \t]+$/, "", $i)
			if (i > 1) printf ","
			printf "\"%s\"", $i
		}
		printf "]"
	}')"
	FIRST_SHORT_ID="$(printf '%s' "${REALITY_SHORT_IDS}" | cut -d',' -f1 | tr -d '[:space:]')"

	GOST_ARGS=""
	if [ "${GOST_ENABLE:-0}" = "1" ]; then
		if [ -n "${GOST_FORWARD_TCP:-}" ]; then
			GOST_ARGS="-L tcp://:${GOST_LISTEN_PORT}/${GOST_FORWARD_TCP}?keepAlive=true&nodelay=true"
		fi
		if [ -n "${GOST_FORWARD_UDP:-}" ]; then
			GOST_ARGS="${GOST_ARGS:+$GOST_ARGS }-L udp://:${GOST_LISTEN_PORT}/${GOST_FORWARD_UDP}?keepAlive=true&ttl=60s"
		fi
	fi

	export REALITY_SHORT_IDS_JSON FIRST_SHORT_ID GOST_ARGS
}

install_base_packages() {
	detect_os
	case "$OS_ID" in
		debian|ubuntu)
			missing=""
			for pkg_cmd in "curl:curl" "unzip:unzip" "openssl:openssl" "ca-certificates:update-ca-certificates"; do
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
			for pkg_cmd in "curl:curl" "unzip:unzip" "openssl:openssl" "ca-certificates:update-ca-certificates" "iproute2-ss:ss"; do
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

install_xray() {
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
	curl -fsSL --retry 3 --connect-timeout 10 -o "${tmp_dir}/xray.zip" "$url"
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
	curl -fsSL --retry 3 --connect-timeout 10 -o "${tmp_dir}/gost.tar.gz" "$url"
	tar -xzf "${tmp_dir}/gost.tar.gz" -C "$tmp_dir" gost
	install -m 0755 "${tmp_dir}/gost" /usr/local/bin/gost
	rm -rf "$tmp_dir"
	log "installed $(/usr/local/bin/gost -V 2>/dev/null | head -n 1)"
}

ensure_secrets() {
	if [ -f "$SECRETS_ENV" ]; then
		# shellcheck disable=SC1090
		. "$SECRETS_ENV"
	fi

	changed=0
	if [ -z "${VLESS_UUID:-}" ]; then
		VLESS_UUID="$(/usr/local/bin/xray uuid)"
		changed=1
	fi

	if [ -z "${REALITY_PRIVATE_KEY:-}" ] || [ -z "${REALITY_PUBLIC_KEY:-}" ]; then
		key_out="$(/usr/local/bin/xray x25519)"
		REALITY_PRIVATE_KEY="$(printf '%s\n' "$key_out" | awk -F': ' '/Private[Kk]ey|Private key/ {print $2}' | tr -d '[:space:]')"
		REALITY_PUBLIC_KEY="$(printf '%s\n' "$key_out" | awk -F': ' '/Public[Kk]ey|Public key|Password/ {print $2}' | tr -d '[:space:]')"
		[ -n "$REALITY_PRIVATE_KEY" ] && [ -n "$REALITY_PUBLIC_KEY" ] || die "failed to parse xray x25519 output"
		changed=1
	fi

	if [ "$changed" -eq 1 ] || [ ! -f "$SECRETS_ENV" ]; then
		umask 077
		cat > "$SECRETS_ENV" <<EOF
# surge node secrets — generated $(date -u +%Y-%m-%dT%H:%M:%SZ)
VLESS_UUID=${VLESS_UUID}
REALITY_PRIVATE_KEY=${REALITY_PRIVATE_KEY}
REALITY_PUBLIC_KEY=${REALITY_PUBLIC_KEY}
EOF
		chmod 600 "$SECRETS_ENV"
		log "generated secrets in ${SECRETS_ENV}"
	else
		log "keeping existing secrets in ${SECRETS_ENV}"
	fi

	export VLESS_UUID REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY
}

escape_sed() {
	printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}

render_template() {
	src="$1"
	dst="$2"
	mkdir -p "$(dirname "$dst")"
	sed \
		-e "s|\${VLESS_LISTEN_PORT}|$(escape_sed "${VLESS_LISTEN_PORT}")|g" \
		-e "s|\${VLESS_UUID}|$(escape_sed "${VLESS_UUID}")|g" \
		-e "s|\${VLESS_EMAIL}|$(escape_sed "${VLESS_EMAIL}")|g" \
		-e "s|\${REALITY_DEST}|$(escape_sed "${REALITY_DEST}")|g" \
		-e "s|\${REALITY_SNI}|$(escape_sed "${REALITY_SNI}")|g" \
		-e "s|\${REALITY_PRIVATE_KEY}|$(escape_sed "${REALITY_PRIVATE_KEY}")|g" \
		-e "s|\${REALITY_PUBLIC_KEY}|$(escape_sed "${REALITY_PUBLIC_KEY}")|g" \
		-e "s|\${REALITY_MIN_CLIENT_VER}|$(escape_sed "${REALITY_MIN_CLIENT_VER}")|g" \
		-e "s|\${REALITY_SHORT_IDS_JSON}|$(escape_sed "${REALITY_SHORT_IDS_JSON}")|g" \
		-e "s|\${GOGC}|$(escape_sed "${GOGC}")|g" \
		-e "s|\${GOMAXPROCS}|$(escape_sed "${GOMAXPROCS}")|g" \
		-e "s|\${XRAY_GOMEMLIMIT}|$(escape_sed "${XRAY_GOMEMLIMIT}")|g" \
		-e "s|\${GOST_GOMEMLIMIT}|$(escape_sed "${GOST_GOMEMLIMIT}")|g" \
		-e "s|\${GOST_ARGS}|$(escape_sed "${GOST_ARGS}")|g" \
		"$src" > "$dst"
}

render_gost_config() {
	mkdir -p /etc/gost
	set -- -C '{"log":{"level":"warn","output":"stderr"}}'
	if [ -n "${GOST_FORWARD_TCP:-}" ]; then
		set -- "$@" -L "tcp://:${GOST_LISTEN_PORT}/${GOST_FORWARD_TCP}?keepAlive=true&nodelay=true"
	fi
	if [ -n "${GOST_FORWARD_UDP:-}" ]; then
		set -- "$@" -L "udp://:${GOST_LISTEN_PORT}/${GOST_FORWARD_UDP}?keepAlive=true&ttl=60s"
	fi
	/usr/local/bin/gost "$@" -O json > /etc/gost/config.json
	chmod 0600 /etc/gost/config.json
}

resolve_ipv4_dns() {
	host="$1"
	ip=""
	if command -v resolvectl >/dev/null 2>&1; then
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
	reality_host="${REALITY_DEST%:*}"
	entries=""

	if [ -n "$reality_host" ]; then
		rip="$(resolve_ipv4_dns "$reality_host")"
		if [ -n "$rip" ]; then
			entries="${rip} ${reality_host}"
		fi
	fi

	if [ "${GOST_ENABLE:-0}" = "1" ] && [ -n "${GOST_FORWARD_TCP:-}" ]; then
		gost_host="${GOST_FORWARD_TCP%:*}"
		if [ -n "$gost_host" ] && [ "$gost_host" != "$reality_host" ]; then
			gip="$(resolve_ipv4_dns "$gost_host")"
			if [ -n "$gip" ]; then
				entries="${entries:+${entries}
}${gip} ${gost_host}"
			fi
		fi
	fi

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

	# Scale socket buffers to available memory (conserve RAM on 256-512M LXC containers)
	if [ "$MEM_MB" -le 512 ]; then
		rmem_max=8388608
		wmem_max=8388608
	else
		rmem_max=33554432
		wmem_max=33554432
	fi

	# Probe each sysctl before persisting so unprivileged LXC containers never log boot errors
	mkdir -p /etc/sysctl.d
	: > /etc/sysctl.d/99-surge.conf
	while IFS='=' read -r k v; do
		[ -n "$k" ] || continue
		if sysctl -w "${k}=${v}" >/dev/null 2>&1; then
			printf '%s = %s\n' "$k" "$v" >> /etc/sysctl.d/99-surge.conf
		fi
	done <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.core.rmem_max=${rmem_max}
net.core.wmem_max=${wmem_max}
net.ipv4.tcp_rmem=4096 65536 ${rmem_max}
net.ipv4.tcp_wmem=4096 65536 ${wmem_max}
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15
net.core.somaxconn=4096
EOF

	if [ "$INIT_SYSTEM" = "systemd" ]; then
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
		ufw allow "${VLESS_LISTEN_PORT}/tcp" comment "surge vless (${NODE_NAME})" >/dev/null 2>&1 || true
		if [ "${GOST_ENABLE:-0}" = "1" ]; then
			[ -n "${GOST_FORWARD_TCP:-}" ] && ufw allow "${GOST_LISTEN_PORT}/tcp" comment "surge gost tcp (${NODE_NAME})" >/dev/null 2>&1 || true
			[ -n "${GOST_FORWARD_UDP:-}" ] && ufw allow "${GOST_LISTEN_PORT}/udp" comment "surge gost udp (${NODE_NAME})" >/dev/null 2>&1 || true
		fi
		log "ensured ufw rules for surge (${NODE_NAME})"
	fi
}

cleanup_legacy_services() {
	# Remove unused hysteria test artifacts if present on NAT nodes (frees ~24MB binary + RAM)
	if [ "${NODE_NAME:-}" != "verge2" ]; then
		if [ "$INIT_SYSTEM" = "openrc" ] && [ -f /etc/init.d/hysteria ]; then
			log "stopping and removing legacy hysteria service on ${NODE_NAME}"
			rc-service hysteria stop >/dev/null 2>&1 || true
			rc-update del hysteria default >/dev/null 2>&1 || true
			rm -f /etc/init.d/hysteria /usr/local/bin/hysteria /var/log/hysteria.log
			rm -rf /etc/hysteria
		elif [ "$INIT_SYSTEM" = "systemd" ] && [ -f /etc/systemd/system/hysteria2.service ]; then
			systemctl disable --now hysteria2 >/dev/null 2>&1 || true
			rm -f /etc/systemd/system/hysteria2.service /usr/local/bin/hysteria
			systemctl daemon-reload >/dev/null 2>&1 || true
		fi
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
OnBootSec=1min
OnUnitActiveSec=2min
AccuracySec=15s

[Install]
WantedBy=timers.target
EOF
		systemctl daemon-reload
		systemctl enable --now surge-watchdog.timer >/dev/null 2>&1
	elif [ -d /etc/crontabs ]; then
		watchdog_cmd="*/2 * * * * ${SURGE_ROOT}/scripts/watchdog.sh >/dev/null 2>&1"
		touch /etc/crontabs/root
		grep -v "${SURGE_ROOT}/scripts/watchdog.sh" /etc/crontabs/root > /etc/crontabs/root.tmp || true
		printf '%s\n' "$watchdog_cmd" >> /etc/crontabs/root.tmp
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

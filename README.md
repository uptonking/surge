# surge — Lightweight Multi-OS VLESS+Reality+Vision, Hysteria2 & Flexible gost Automation Stack

Zero-Docker, resource-optimized proxy and relay automation stack designed for NAT/LXC and dedicated Linux VPS nodes running **Debian/Ubuntu (`systemd`)** or **Alpine Linux (`OpenRC`)**.

- **Default Service (`XRAY_ENABLE=1`)**: **Xray (`VLESS + Reality + XTLS-Vision`)** over TCP (`v26.6.27` pinned for Mihomo / Clash.Meta compatibility). Extracted without `geoip.dat`/`geosite.dat` bloat (~20 MiB RAM, ~24 MiB disk), with built-in in-memory `serveStale` IPv4 DNS caching, `happyEyeballs` outbound TCP racing, and NAT-friendly TCP keepalives.
- **Optional Hysteria2 QUIC Service (`HYSTERIA_ENABLE=1`, default on `stash1`/`stash2`)**: **Hysteria2 (`v2.13.0`)** over UDP with LXC-safe `quic-go` tuning (`QUIC_GO_DISABLE_GSO=true`, compact QUIC stream/connection receive windows, `GOMEMLIMIT=48MiB`) and dual-mode TLS (`acme-dns` via `HYSTERIA_CF_DNS_TOKEN` in `.env` with automatic fallback to a 10-year ECDSA P-256 `self-signed` certificate). Can share the same NAT port (`23112 -> 80/tcp,udp`) with `gost` TCP forwarding (`80/udp` for Hysteria2 + `80/tcp` for `gost`).
- **Flexible Vendor-Neutral `gost` Service (`GOST_ENABLE=1`)**: **`gost` (`v3.3.0`)** supporting:
  1. **Shorthand TCP/UDP Port Forwarding**: `GOST_FORWARD_TCP` / `GOST_FORWARD_UDP` (single or multiple `[listen_port/]host:port` mappings).
  2. **Arbitrary Proxy / Tunnel / Relay Rules**: `GOST_RULES` (`-L tcp://...`, `-L socks5://...`, `-L http://...`, `-L wss://...`, `-L sni://...`) and `GOST_CHAINS` (`-F relay+tls://...`, `-F wss://...`).
  3. **Custom Declarative Config Template**: `GOST_CONFIG_TEMPLATE=services/gost/config.json.example`.
- **Auto-Select OS, BBR & Resource Profile**: Automatically detects `systemd` (Debian/Ubuntu) vs `OpenRC` (Alpine), LXC cgroup memory limits, and configures Go runtime memory caps (`GOGC`, `GOMEMLIMIT`, `GOMAXPROCS`), `/etc/sysctl.d/99-bbr.conf` (`bbr`, `fq`, `tcp_fastopen=3`, 64 MiB socket buffers, `tcp_moderate_rcvbuf=1`, `tcp_notsent_lowat=16384`, `tcp_mtu_probing=1`), `/etc/hosts` IPv4 pinning, boot services, and a 2-minute watchdog (`systemd` timer or OpenRC `crond`).

---

## Architecture & Topology

```text
Mac Client (ClashX Meta: ~/.config/clash.meta/verge2609.yaml)
  │
  ├──► Surge1       : surge1.aichorage.de:23111       ──► NAT 23111->443/tcp ──► surge1 Xray (Debian 13 / systemd)
  ├──► Surge2       : surge2.aichorage.de:23121       ──► NAT 23121->443/tcp ──► surge2 Xray (Alpine 3.23 / OpenRC)
  ├──► Surge3       : surge3.aichorage.de:23131       ──► NAT 23131->443/tcp ──► surge3 Xray (Alpine 3.23 / OpenRC)
  ├──► Surge1-Relay : surge1-relay.aichorage.de:23112 ──► NAT 23112->80/tcp  ──► surge1 gost ──► verge2.aichorage.de:8443
  ├──► Verge2       : verge2.aichorage.de:8443        ─────────────────────────────────────────► verge2 Xray (worker_2 / systemd)
  ├──► Verge2-Hy2   : verge2.aichorage.de:443/udp     ─────────────────────────────────────────► verge2 Hysteria2 (worker_2)
  │
  ├──► Stash1       : stash1.aichorage.de:23111       ──► NAT 23111->443/tcp ──► stash1 Xray (Debian 12 / systemd)
  ├──► Stash1-Hy2   : stash1.aichorage.de:23112       ──► NAT 23112->80/udp  ──► stash1 Hysteria2 (Debian 12 / systemd)
  ├──► Stash1-Relay : stash1-relay.aichorage.de:23112 ──► NAT 23112->80/tcp  ──► stash1 gost ──► verge4.aichorage.de:8443
  ├──► Stash2       : stash2.aichorage.de:23121       ──► NAT 23121->443/tcp ──► stash2 Xray (Debian 12 / systemd)
  ├──► Stash2-Hy2   : stash2.aichorage.de:23122       ──► NAT 23122->80/udp  ──► stash2 Hysteria2 (Debian 12 / systemd)
  ├──► Verge4       : verge4.aichorage.de:8443        ─────────────────────────────────────────► verge4 Xray (worker_4 / systemd)
  └──► Verge4-Hy2   : verge4.aichorage.de:443/udp     ─────────────────────────────────────────► verge4 Hysteria2 (worker_4)
```

---

## Quickstart (Any VPS)

### 1. Using a Committed Node Profile (`nodes/<node>.env`)
```sh
git clone https://github.com/uptonking/surge.git /opt/surge
cd /opt/surge
./scripts/bootstrap.sh <node_name>   # e.g. surge1, surge2, surge3, verge2, stash1, stash2, verge4
```

### 2. Deploying to Any Ad-Hoc VPS (Without Creating a Profile First)
```sh
git clone https://github.com/uptonking/surge.git /opt/surge
cd /opt/surge
NODE_HOST=stash3.aichorage.de PUBLIC_VLESS_PORT=23131 HYSTERIA_ENABLE=1 PUBLIC_HYSTERIA_PORT=23132 ./scripts/bootstrap.sh stash3
```

### 3. Enabling `gost` Forwarding or Proxying on `surge2` / `surge3` / Any Node
Use `./scripts/gost.sh` (persists settings in `/opt/surge/.env` across `git pull` and `reboot`), or pass environment variables to `./scripts/deploy.sh`:
```sh
# Mode 1: Enable pre-wired forwarding (or specify any custom TCP/UDP target)
./scripts/gost.sh enable
./scripts/gost.sh forward verge2.aichorage.de:8443 verge2.aichorage.de:443
./scripts/gost.sh forward 80/new-service.example.com:8080

# Mode 2: Any vendor/framework-neutral gost v3 listener / proxy / chain
./scripts/gost.sh rules "-L tcp://:80/upstream.example.com:443" "-F relay+tls://next-hop.example.com:8443"

# Mode 3: Custom declarative JSON config template
./scripts/gost.sh template services/gost/config.json.example

# Disable gost on the node
./scripts/gost.sh disable
```

---

## Operations

| Command | Description |
| :--- | :--- |
| `./scripts/bootstrap.sh [node]` | First-time setup on a VPS (selects `nodes/<node>.env` or ad-hoc env, generates `.env`, deploys services) |
| `./scripts/deploy.sh [node]` | Pull latest git changes, re-render configs/units, apply `99-bbr.conf`, refresh `/etc/hosts`, and restart services |
| `./scripts/gost.sh <cmd>` | Manage `gost` (`status`, `enable`, `forward`, `rules`, `template`, `disable`) and persist to `.env` |
| `./scripts/test.sh` | Run local node self-tests (syntax, config validation, active services, listening sockets, Reality target, `99-bbr.conf`) |
| `./scripts/test.sh --remote` | Run remote SSH self-tests across all nodes + live local ClashX Meta delay checks |
| `./scripts/status.sh` | Show service state, boot enablement, watchdog state, listening sockets, RSS memory, and client config |
| `./scripts/client.sh` | Print `vless://` URI and ClashX Meta YAML proxy lines |
| `./scripts/restart.sh` | Restart enabled services (`xray` and optional `gost`) |
| `./scripts/stop.sh` | Stop running services |
| `./scripts/logs.sh [xray\|gost]` | Tail service logs (`journalctl` on Debian/Ubuntu, `/var/log/<svc>.log` on Alpine) |

---

## License

MIT — see [LICENSE.md](LICENSE.md).

# surge — Lightweight Multi-OS VLESS+Reality+Vision & gost Automation Stack

Zero-Docker, resource-optimized proxy and relay automation stack designed for NAT/LXC and dedicated Linux VPS nodes running **Debian/Ubuntu (`systemd`)** or **Alpine Linux (`OpenRC`)**.

- **Default Service**: **Xray (`VLESS + Reality + XTLS-Vision`)** over TCP (`v26.6.27` pinned for Mihomo / Clash.Meta compatibility). Extracted without `geoip.dat`/`geosite.dat` bloat (~20 MiB RAM, ~24 MiB disk), with built-in in-memory `serveStale` IPv4 DNS caching and NAT-friendly TCP keepalives.
- **Optional Relay Service**: **`gost` (`v3.3.0`)** raw TCP/UDP port forwarder (`GOST_ENABLE=1`), allowing a low-latency transit NAT VPS (`surge1-relay.aichorage.de`) to forward traffic to a clean-IP egress node (`verge2.aichorage.de`).
- **Auto-Select OS & Resource Profile**: Automatically detects `systemd` (Debian/Ubuntu) vs `OpenRC` (Alpine), LXC cgroup memory limits, and configures Go runtime memory caps (`GOGC`, `GOMEMLIMIT`, `GOMAXPROCS`), container-safe kernel BBR/TCP Fast Open sysctls, `/etc/hosts` IPv4 pinning, boot services, and a 2-minute watchdog (`systemd` timer or OpenRC `crond`).

---

## Architecture & Topology

```text
Mac Client (ClashX Meta: ~/.config/clash.meta/verge2609.yaml)
  │
  ├──► Surge1       : surge1.aichorage.de:23111       ──► NAT 23111->443/tcp ──► surge1 Xray (Debian 13 / systemd)
  ├──► Surge2       : surge2.aichorage.de:23121       ──► NAT 23121->443/tcp ──► surge2 Xray (Alpine 3.23 / OpenRC)
  ├──► Surge3       : surge3.aichorage.de:23131       ──► NAT 23131->443/tcp ──► surge3 Xray (Alpine 3.23 / OpenRC)
  │
  ├──► Surge1-Relay : surge1-relay.aichorage.de:23112 ──► NAT 23112->80/tcp  ──► surge1 gost ──► verge2.aichorage.de:8443
  ├──► Verge2       : verge2.aichorage.de:8443        ─────────────────────────────────────────► verge2 Xray (worker_2 / systemd)
  └──► Verge2-Hy2   : verge2.aichorage.de:443/udp     ─────────────────────────────────────────► verge2 Hysteria2 (worker_2)
```

---

## Quickstart (Any VPS)

### 1. Using a Committed Node Profile (`nodes/<node>.env`)
```sh
git clone https://github.com/uptonking/surge.git /opt/surge
cd /opt/surge
./scripts/bootstrap.sh <node_name>   # e.g. surge1, surge2, surge3, verge2
```

### 2. Deploying to Any Ad-Hoc VPS (Without Creating a Profile First)
```sh
git clone https://github.com/uptonking/surge.git /opt/surge
cd /opt/surge
NODE_HOST=surge4.aichorage.de PUBLIC_VLESS_PORT=23141 VLESS_LISTEN_PORT=443 ./scripts/bootstrap.sh surge4
```

`bootstrap.sh` records the selected node in `.node`, installs minimal OS packages, downloads the pinned `xray` binary (and `gost` when `GOST_ENABLE=1`), generates `.env` secrets (`VLESS_UUID`, `REALITY_PRIVATE_KEY`, `REALITY_PUBLIC_KEY`) idempotently, enables boot services + watchdog, and prints the ready-to-use `vless://` URI and ClashX Meta YAML lines.

---

## Operations

| Command | Description |
| :--- | :--- |
| `./scripts/bootstrap.sh [node]` | First-time setup on a VPS (selects `nodes/<node>.env` or ad-hoc env, generates `.env`, deploys services) |
| `./scripts/deploy.sh [node]` | Pull latest git changes, re-render configs/units, refresh `/etc/hosts`, and restart services |
| `./scripts/test.sh` | Run local node self-tests (syntax, config validation, active services, listening sockets, Reality target, BBR) |
| `./scripts/test.sh --remote` | Run remote SSH self-tests across all nodes + live local ClashX Meta delay checks |
| `./scripts/status.sh` | Show service state, boot enablement, watchdog state, listening sockets, RSS memory, and client config |
| `./scripts/client.sh` | Print `vless://` URI and ClashX Meta YAML proxy lines |
| `./scripts/restart.sh` | Restart enabled services (`xray` and optional `gost`) |
| `./scripts/stop.sh` | Stop running services |
| `./scripts/logs.sh [xray\|gost]` | Tail service logs (`journalctl` on Debian/Ubuntu, `/var/log/<svc>.log` on Alpine) |

---

## Configuration Model

| Path | Committed? | Purpose |
| :--- | :---: | :--- |
| `config.env` | Yes | Shared defaults (`XRAY_VERSION`, `REALITY_*`, `TCP_KEEPALIVE_*`, `GOST_*`) |
| `nodes/<node>.env` | Yes | Per-node overrides (`NODE_HOST`, `PUBLIC_VLESS_PORT`, `VLESS_LISTEN_PORT`, `GOST_ENABLE`, `SSH_TARGET`) |
| `.node` | No | Local file storing the active node profile name on that VPS |
| `.env` | No | Node secrets (`VLESS_UUID`, `REALITY_PRIVATE_KEY`, `REALITY_PUBLIC_KEY`) and optional ad-hoc overrides |
| `services/xray/config.json.template` | Yes | GeoIP-free Xray `VLESS + Reality + Vision` template with `serveStale` IPv4 DNS cache |
| `services/systemd/*.template` | Yes | Debian/Ubuntu `systemd` unit templates |
| `services/openrc/*.template` | Yes | Alpine `OpenRC` `supervise-daemon` init templates |

---

## License

MIT — see [LICENSE.md](LICENSE.md).

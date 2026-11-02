# surge — Lightweight Multi-OS VLESS+Reality+Vision & gost Automation Stack

Zero-Docker, resource-optimized proxy and relay automation stack designed for NAT/LXC and dedicated Linux VPS nodes running **Debian/Ubuntu (`systemd`)** or **Alpine Linux (`OpenRC`)**.

- **Default Service**: **Xray (`VLESS + Reality + XTLS-Vision`)** over TCP (`v26.6.27` pinned for Mihomo / Clash.Meta compatibility). Extracted without `geoip.dat`/`geosite.dat` bloat (~15 MiB RAM, ~24 MiB disk).
- **Optional Relay Service**: **`gost` (`v3.3.0`)** raw TCP/UDP port forwarder (`GOST_ENABLE=1`), allowing a low-latency transit NAT VPS (`surge1-relay.aichorage.de`) to forward traffic to a clean-IP egress node (`verge2.aichorage.de`).
- **Auto-Select OS & Resource Profile**: Automatically detects `systemd` (Debian/Ubuntu) vs `OpenRC` (Alpine), LXC memory limits, and configures Go runtime memory caps (`GOGC`, `GOMEMLIMIT`, `GOMAXPROCS`), kernel BBR/TCP Fast Open sysctls, boot services, and a 2-minute cron watchdog.

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

```sh
git clone https://github.com/uptonking/surge.git /opt/surge
cd /opt/surge
./scripts/bootstrap.sh <node_name>   # e.g. surge1, surge2, surge3, verge2
```

`bootstrap.sh` records the selected node profile in `.node`, installs minimal OS packages, downloads the pinned `xray` binary (and `gost` when `GOST_ENABLE=1`), generates `.env` secrets (`VLESS_UUID`, `REALITY_PRIVATE_KEY`, `REALITY_PUBLIC_KEY`) idempotently, enables boot services, and prints the ready-to-use `vless://` URI and ClashX Meta YAML lines.

---

## Operations

| Command | Description |
| :--- | :--- |
| `./scripts/bootstrap.sh [node]` | First-time setup on a VPS (selects `nodes/<node>.env`, generates `.env`, deploys services) |
| `./scripts/deploy.sh [node]` | Pull latest git changes, re-render configs/units, and restart services |
| `./scripts/status.sh` | Show service state, boot enablement, listening sockets, RSS memory, and client config |
| `./scripts/client.sh` | Print `vless://` URI and ClashX Meta YAML proxy lines |
| `./scripts/restart.sh` | Restart enabled services (`xray` and optional `gost`) |
| `./scripts/stop.sh` | Stop running services |
| `./scripts/logs.sh [xray\|gost]` | Tail service logs (`journalctl` on Debian/Ubuntu, `/var/log/<svc>.log` on Alpine) |

---

## Configuration Model

| Path | Committed? | Purpose |
| :--- | :---: | :--- |
| `config.env` | Yes | Shared defaults (`XRAY_VERSION`, `REALITY_*`, `GOST_*`) |
| `nodes/<node>.env` | Yes | Per-node overrides (`NODE_HOST`, `PUBLIC_VLESS_PORT`, `VLESS_LISTEN_PORT`, `GOST_ENABLE`) |
| `.node` | No | Local file storing the active node profile name on that VPS |
| `.env` | No | Node secrets (`VLESS_UUID`, `REALITY_PRIVATE_KEY`, `REALITY_PUBLIC_KEY`) |
| `services/xray/config.json.template` | Yes | GeoIP-free Xray `VLESS + Reality + Vision` template |
| `services/systemd/*.template` | Yes | Debian/Ubuntu `systemd` unit templates |
| `services/openrc/*.template` | Yes | Alpine `OpenRC` `supervise-daemon` init templates |

---

## License

MIT — see [LICENSE.md](LICENSE.md).

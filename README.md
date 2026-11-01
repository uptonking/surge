# surge — VPS services stack

Reproducible proxying/forwarding stack for a NAT/LXC linux VPS: [Caddy](https://caddyserver.com/) (automatic TLS) + vless proxy ( `surge` , UDP/QUIC 443) sharing one Let's Encrypt certificate. Optionally includes a [gost](https://gost.run/) TCP forwarder ( `forward` profile) that relays a VLESS+Reality entrypoint to a separate, good-IP "indigenous" VPS. Config-as-code: desired state lives in git, secrets stay on the VPS.

## Architecture

```
                      Internet
                          |
        +-----------------+------------------+
        |                 |                  |
   TCP 80/443   UDP 443 + 20000-30000    (any client)
        |                 |                  |
  +-----v-----+    +------v------+           |
  |   caddy   |    |    verges   |           |
  | TLS entry |    | hysteria2   |           |
  | h1/h2 only|    | QUIC proxy  |           |
  +-----+-----+    +------+------+           |
                        (host network)
        |                 |  masquerade      |
        |  +--------------+  (in-network)    |
        +->| shared_network (bridge) |<------+
           +-------------------------+

  cert flow: caddy obtains/renews LE cert for verges.<domain>
             -> stored in ./data/caddy
             -> mounted read-only into verges
             -> hysteria hot-reloads on renewal (no restart)
```

- **caddy** always runs: TCP 80 (ACME HTTP-01 + redirects) and TCP 443 (HTTPS, h1/h2 — HTTP/3 is disabled because UDP 443 belongs to verges).
- **verges** (Hysteria 2): UDP 443 + server-side port hopping range (default `20000-30000/udp`), enabled/disabled via compose profiles. Unauthenticated traffic is masqueraded to caddy in-network (`It works!` page), so the endpoint looks like a normal HTTPS site.

## Quickstart (fresh VPS)

Prerequisite: a DNS A record `verges.<your-domain>` → VPS IP (DNS-only, no proxy).

```bash
ssh root@<vps>
git clone https://github.com/uptonking/verges.git /opt/verges
cd /opt/verges
scripts/bootstrap.sh
```

Bootstrap checks prerequisites, generates `.env` (secrets) interactively, verifies DNS, adds ufw rules, starts the stack, waits for the certificate, and prints the Hysteria2 client URI.

## Operations (always use the scripts)

| Command | Purpose |
|---|---|
| `scripts/bootstrap.sh` | One-time setup on a fresh VPS |
| `scripts/deploy.sh` | Apply latest git state (pull + regen configs + recreate). Also the enable/disable path. |
| `scripts/restart.sh` | Restart all services |
| `scripts/stop.sh` | Stop all services (containers kept; they return after reboot) |
| `scripts/status.sh` | Containers, DNS, listeners, certificate, client URI |
| `scripts/logs.sh [svc]` | Follow logs (e.g. `scripts/logs.sh verges` ) |
| `scripts/update.sh` | Re-pull the pinned images and recreate |
| `scripts/caddy-reload.sh` | Validate + gracefully reload Caddyfile |

Plain `docker compose` also works for inspection but misses `config.env` (profiles, domain) — the scripts pass `--env-file config.env --env-file .env` on every invocation.

## Configuration model

| File | Committed? | Contents |
|---|---|---|
| `config.env` | yes | Desired state: `COMPOSE_PROFILES` , `DOMAIN_NAME` , `VERGES_PORT` , `VERGES_HOP_RANGE` , `FORWARD_*` , image pins |
| `.env` | no (generated) | Secrets only: `SSL_EMAIL` , `VERGES_PASSWORD` |
| `indigenous-node/` | yes | Separate self-contained script suite for the VLESS+Reality egress VPS |
| `caddy/` | yes | Caddyfile + per-site files ( `import sites/*.caddy` ) |
| `services/verges/config.yaml.template` | yes | Hysteria config template (envsubst → generated `config.yaml` , gitignored) |
| `data/` | no | Runtime data (caddy certificate storage) |

### Daily flow

1. Edit locally (e.g. toggle a service, change ports/domain), commit, push to GitHub.
2. On the VPS: `cd /opt/verges && scripts/deploy.sh`.

### Enable / disable services

Services run behind compose profiles; caddy has no profile (always on). To disable verges:

```bash
# in config.env:  COMPOSE_PROFILES=
git commit -am "disable verges" && git push
# on VPS:
scripts/deploy.sh   # --remove-orphans removes the disabled container
```

Re-enable with `COMPOSE_PROFILES=verges` . Add the gost forwarder with `COMPOSE_PROFILES=verges,forward` .

### Changing the VPS IP

Update only the DNS A record for `verges.<domain>` to point to the new VPS IP. The repo no longer stores the VPS IP. Data (certificates) can be migrated manually by copying `data/` ; otherwise a fresh bootstrap on the new VPS re-issues everything.

## Client setup

`scripts/status.sh` prints the ready-to-use URI:

```
hysteria2://<password>@verges.<domain>:443?sni=verges.<domain>&insecure=0
```

For clients that support port hopping (e.g. Clash. Meta), also configure `ports: 20000-30000` and `hop-interval: 30` .

Works with any Hysteria2 client (official CLI, sing-box, Clash. Meta, Stash, Shadowrocket, ...).

## VLESS+Reality relay (indigenous node)

When the primary VPS has poor IP quality for some services, enable the `forward` profile and deploy a separate small VPS with `indigenous-node/` .

```text
Four client modes, two transports:

VLESS+Reality (TCP fallback, ~3-RTT handshake):
  relay  : client ──► edge.<domain>:8443 ──► primary gost tcp ──► indigenous:8443
  direct : client ───────────────────────► edge-direct.<domain>:443

Hysteria2/QUIC (low latency, ~1-RTT handshake, needs UDP):
  relay  : client ──► edge.<domain>:8443/udp ──► primary gost udp ──► indigenous:443/udp
  direct : client ─────────────────────────► edge-direct.<domain>:443/udp
                                                              │
                                    indigenous node (3x-ui/xray + standalone hysteria2)
                                                              ▼
                                    Internet (egress IP = indigenous)
```

gost relays both protocols on `FORWARD_PORT` (TCP → `FORWARD_TARGET` , UDP → `FORWARD_TARGET_UDP` ), so every mode works with or without the primary: if gost is down only the relay modes are affected.

**Switching modes** (see `indigenous-node/README.md` ):

1. In the client: pick any of the four proxies (all emitted by `client.sh`).
2. In the 3x-ui webapp: toggle each VLESS inbound's enable switch (hysteria2 is standalone, managed by `deploy.sh`).
3. Via config: set `DIRECT_INBOUND_ENABLE` / `RELAY_INBOUND_ENABLE` in `indigenous-node/config.env`, run `./deploy.sh` (flags are the source of truth).
4. To disable the whole relay path, remove `forward` from `COMPOSE_PROFILES` on the primary.

Prerequisites:

- Two DNS A records (DNS-only / grey cloud):
  - `edge.<domain>` → primary VPS IP
  - `edge-direct.<domain>` → indigenous VPS IP
- Set `COMPOSE_PROFILES=verges,forward` in `config.env`.

On the indigenous VPS:

```bash
git clone https://github.com/uptonking/verges.git /opt/verges
cd /opt/verges/indigenous-node
./bootstrap.sh
```

See `indigenous-node/README.md` for full details.

## Notes

## License

MIT — see [LICENSE.md](LICENSE.md).

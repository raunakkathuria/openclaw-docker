# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A hardened Docker/Podman deployment of OpenClaw (self-hosted AI agent gateway). It solves three non-obvious problems that the upstream docs don't address: the loopback networking deadlock, permission errors from partial volume mounts, and the device-pairing bootstrap issue in containerized deployments.

## Key commands

```bash
# First-time setup (detects Docker vs Podman, creates dirs, copies configs, starts services, applies runtime config)
./setup.sh

# Start / stop
docker compose up -d
docker compose down

# View gateway logs
docker compose logs -f openclaw-gateway

# Restart gateway (required after editing data/config/openclaw.json)
docker compose restart openclaw-gateway

# Health check
curl http://localhost:18789/healthz

# Security audit
docker compose exec openclaw-gateway node openclaw.mjs security audit

# Read/write runtime config (trustedProxies, allowedOrigins — NOT in JSON5 file)
docker compose exec openclaw-gateway node openclaw.mjs config get <path>
docker compose exec openclaw-gateway node openclaw.mjs config set <path> <value>

# Device pairing (first login — see README)
docker compose exec openclaw-gateway node openclaw.mjs devices list
docker compose exec openclaw-gateway node openclaw.mjs devices approve <REQUEST_ID>

# Add messaging channel (Telegram/Discord)
docker compose exec openclaw-gateway node openclaw.mjs channels add \
  --channel telegram --token "<BOT_TOKEN>"

# One-off CLI commands (uses the cli profile)
docker compose run --rm openclaw-cli <subcommand>
```

Replace `docker compose` with `podman-compose` (or `podman compose`) when using Podman.

## Architecture

```
Browser → host:18789 → Docker port-map → container:18800
                                               ↓
                                    openclaw-proxy-ws  (alpine/socat)
                                    0.0.0.0:18800 → 127.0.0.1:18789
                                    [shares gateway network namespace]
                                               ↓
                                    openclaw-gateway
                                    node openclaw.mjs · 127.0.0.1:18789
                                    ./data → /home/node/.openclaw
                                               ↓ spawns via Docker socket
                                    agent sandbox containers (ephemeral)
                                    network:none · capDrop:ALL · readOnlyRoot · 1g RAM
```

**The socat sidecar is the critical non-obvious piece.** OpenClaw's gateway always binds to `127.0.0.1` (loopback). Docker port-forwarding delivers to the container's `eth0` — a different address. The socat container shares the gateway's network namespace so it can see both interfaces, bridging the gap. Without it, `curl localhost:18789` returns an empty reply even though the gateway is running.

## Services

| Service | Image | Notes |
|---------|-------|-------|
| `openclaw-gateway` | `ghcr.io/openclaw/openclaw` | Main process; mounts `./data` as `/home/node/.openclaw` |
| `openclaw-proxy-ws` | `alpine/socat` | Bridges port 18800 → 18789 (web UI + WS) |
| `openclaw-proxy-browser` | `alpine/socat` | Bridges port 18802 → 18791 (browser control) |
| `openclaw-cli` | `ghcr.io/openclaw/openclaw` | On-demand CLI; `profiles: [cli]` |
| `browserless` | `ghcr.io/browserless/chromium` | Optional headless browser; `profiles: [browserless]` |

## Config system (two separate stores)

**1. `data/config/openclaw.json` (JSON5 — startup config, gitignored)**
- Copy from `data/config/openclaw.json.example` on first run (done by `setup.sh`)
- Controls: `gateway.mode`, `gateway.bind`, agent sandbox defaults, channels
- Requires a gateway restart after changes: `docker compose restart openclaw-gateway`
- **`gateway.trustedProxies` is silently ignored here** — must use `config set` instead

**2. `data/openclaw.json` (JSON — runtime config, gitignored)**
- Written by `node openclaw.mjs config set ...`
- Controls: `gateway.trustedProxies`, `gateway.controlUi.allowedOrigins`
- `setup.sh` applies these automatically on first run

## First login — device pairing

Docker NAT makes the browser appear non-local, so OpenClaw shows "pairing required" on first open. Approve from inside the container (trusted local loopback path — no `--url` or `--token` needed):

```bash
docker compose exec openclaw-gateway node openclaw.mjs devices list
# → copy the UUID under "Pending"
docker compose exec openclaw-gateway node openclaw.mjs devices approve <UUID>
# → refresh browser
```

After a gateway restart: clear browser local storage for `http://127.0.0.1:18789`, then re-pair.

**Critical: never add `--url ws://127.0.0.1:18789` to exec commands.** Adding `--url` explicitly sets `Source: cli --url` which the gateway treats as a non-local client requiring device pairing — even though the IP is loopback. Without `--url`, the CLI defaults to `Source: local loopback` which is unconditionally trusted. This is why adding `--url` breaks on Docker but was coincidentally tolerated on Podman.

## Podman differences

- Port binding: `setup.sh` sets `OPENCLAW_BIND=0.0.0.0` automatically (pasta networking can't forward loopback-only ports)
- Sandbox: On macOS, the Podman Machine API socket can't be bind-mounted into VM containers — `setup.sh` detects this and sets `OPENCLAW_SANDBOX=0`
- Startup order: `setup.sh` starts the gateway first, waits for healthy status, then starts socat proxies (Podman compose doesn't reliably honor `depends_on: service_healthy` for `network_mode: "service:X"`)

## `.env` variables

| Variable | Purpose |
|----------|---------|
| `ANTHROPIC_API_KEY` | Required — passed to gateway |
| `OPENCLAW_GATEWAY_TOKEN` | Auth token; generate with `openssl rand -hex 32` |
| `OPENCLAW_IMAGE` | Gateway image tag (default: `ghcr.io/openclaw/openclaw:latest`) |
| `OPENCLAW_PORT` | Host port for web UI (default: `18789`) |
| `OPENCLAW_BIND` | Host bind address; auto-set by `setup.sh` for Podman/macOS |
| `OPENCLAW_SANDBOX` | `1` to enable per-agent container isolation; `0` to disable |
| `DOCKER_SOCKET` | Path to Docker/Podman socket; auto-detected by `setup.sh` |

## What's gitignored

- `.env` — contains API keys and gateway token
- `data/config/openclaw.json` — may contain channel bot tokens
- `data/openclaw.json` — runtime config written by CLI (updated with timestamp on every start)
- All of `data/workspace/`, `data/sessions/`, `data/identity/`, etc.
- Only tracked: `.env.example`, `data/config/openclaw.json.example`, `docker-compose.yml`, `setup.sh`

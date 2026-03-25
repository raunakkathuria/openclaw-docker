# OpenClaw — Docker Setup

Self-hosted OpenClaw gateway with per-agent sandbox isolation, running on Docker.

## Architecture

```
Browser / curl
  │
  │ http://localhost:18789
  ▼
┌─────────────────────────────────────────────┐
│  Docker port mapping                        │
│  host:18789 → container:18800               │
└─────────────────┬───────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────┐  ┐
│  openclaw-proxy-ws  (alpine/socat)          │  │ shared
│  0.0.0.0:18800 → 127.0.0.1:18789           │  │ network
├─────────────────────────────────────────────┤  │ namespace
│  openclaw-gateway                           │  │
│  node openclaw.mjs  ·  127.0.0.1:18789     │  │
│  ./data → /home/node/.openclaw              │  │
└─────────────────┬───────────────────────────┘  ┘
                  │ spawns sandbox containers
                  │ via Docker socket
        ┌─────────┴──────────┐
        │  agent-A sandbox   │  (ephemeral, isolated per tool call)
        │  network: none     │  read-only root · capDrop: ALL · 1g RAM
        └────────────────────┘
```

**Why socat?** OpenClaw's gateway always binds to `127.0.0.1` (container loopback). Docker's port forwarding delivers traffic to the container's `eth0` interface — a different address — so they never connect. The socat sidecar shares the gateway's network namespace, listens on `0.0.0.0` (reachable via eth0), and forwards to `127.0.0.1:18789`.

## Quick Start

```bash
# 1. Configure
cp .env.example .env
# Edit .env: set ANTHROPIC_API_KEY and OPENCLAW_GATEWAY_TOKEN

# 2. Generate a gateway token if you don't have one
openssl rand -hex 32

# 3. Start
docker compose up -d

# 4. Verify
curl http://localhost:18789/healthz
# → {"ok":true,"status":"live"}

# 5. Open
open http://localhost:18789
```

## File Layout

```
openclaw-docker/
├── docker-compose.yml       # All services
├── .env.example             # Config template — copy to .env
├── .env                     # Your secrets (git-ignored)
├── setup.sh                 # First-run setup helper
├── data/
│   └── config/
│       └── openclaw.json    # Gateway + agent config (tracked)
│   └── workspace/           # Agent files (git-ignored)
│   └── identity/            # Auth state (git-ignored)
│   └── sessions/            # Session logs (git-ignored)
└── README.md
```

`data/` is mounted as `/home/node/.openclaw` so OpenClaw can create any subdirectory it needs without permission errors.

## Services

| Service | Image | Purpose |
|---------|-------|---------|
| `openclaw-gateway` | `ghcr.io/openclaw/openclaw` | Main gateway process |
| `openclaw-proxy-ws` | `alpine/socat` | Bridges host→loopback for port 18789 |
| `openclaw-proxy-browser` | `alpine/socat` | Bridges host→loopback for port 18791 |
| `openclaw-cli` | `ghcr.io/openclaw/openclaw` | On-demand CLI (profile: cli) |
| `browserless` | `ghcr.io/browserless/chromium` | Headless browser (profile: browserless) |

## Ports

| Host port | Purpose |
|-----------|---------|
| `18789` | Web UI + WebSocket gateway |
| `18790` | Bridge channel (desktop app pairing) |
| `18791` | Browser control UI |

All bound to `127.0.0.1` — local access only.

## Common Commands

```bash
# Start / stop
docker compose up -d
docker compose down

# Logs
docker compose logs -f openclaw-gateway

# Status
docker compose exec openclaw-gateway node openclaw.mjs status

# Security audit
docker compose exec openclaw-gateway node openclaw.mjs security audit

# Approve a paired device
docker compose exec openclaw-gateway node openclaw.mjs devices list
docker compose exec openclaw-gateway node openclaw.mjs devices approve <ID>

# Add a channel (Telegram, Discord, WhatsApp)
docker compose run --rm openclaw-cli channels add --channel telegram --token "<TOKEN>"

# Restart just the gateway (picks up config changes)
docker compose restart openclaw-gateway
```

## Key Config (`data/config/openclaw.json`)

| Setting | Value | Why |
|---------|-------|-----|
| `gateway.mode` | `"local"` | Required for self-hosted — without this, OpenClaw tries to connect to Claude.ai's remote gateway |
| `gateway.bind` | `"lan"` | Accepts port-forwarded connections, not just loopback |
| `gateway.trustedProxies` | `["127.0.0.1","::1"]` | Trusts the socat proxy (same network namespace) |
| `gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback` | `true` | Required with non-loopback bind — uses HTTP Host header for origin check |
| `agents.defaults.sandbox.mode` | `"non-main"` | Each agent's tool calls run in isolated containers |

## Multiple Agents

One gateway manages all agents. Each agent automatically gets its own sandbox container for tool calls — no extra config needed. Create agents via the web UI at `http://localhost:18789`.

## Troubleshooting

**`curl: (52) Empty reply from server`**
The gateway is running but the origin check is blocking the connection. Ensure `dangerouslyAllowHostHeaderOriginFallback: true` is in `data/config/openclaw.json` and restart.

**`EACCES: permission denied, mkdir '/home/node/.openclaw/<dir>'`**
A new OpenClaw subdirectory couldn't be created. Since `./data` is mounted as the entire `.openclaw` dir, this shouldn't happen — check that the volume mount is correct in `docker-compose.yml`.

**Gateway shows "unreachable" in status**
Expected in a container — the gateway's self-probe can't verify external connectivity. As long as `curl http://localhost:18789/healthz` returns `{"ok":true}`, everything is working.

**Port already in use**
Change `OPENCLAW_PORT` in `.env` and restart.

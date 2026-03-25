# OpenClaw — Docker / Podman Setup

Self-hosted OpenClaw gateway with per-agent sandbox isolation, running on Docker or Podman.

## Why this repo?

OpenClaw's [official Docker docs](https://docs.openclaw.ai/install/docker) give you the basics — a single `docker run` or minimal `docker-compose.yml` — but leave several production-readiness gaps that take real debugging to close:

| Problem | What OpenClaw docs say | What this repo does |
|---------|----------------------|---------------------|
| **Networking** | Mount the Docker socket and expose ports | Adds a socat sidecar to bridge Docker port-forwarding to the gateway's loopback listener (the gateway always binds to `127.0.0.1` — Docker's port-forward delivers to `eth0` — they never connect without this) |
| **`EACCES` permission errors** | Mount individual subdirs (`config/`, `workspace/`, `canvas/`) | Mounts the entire `~/.openclaw` directory so OpenClaw can create any new subdirectory it needs without hitting permission errors |
| **Security audit warnings** | Not covered | `0 critical · 0 warn` out of the box: `gateway.trustedProxies` is auto-applied via `setup.sh` (can't be set in the JSON5 file — silently ignored there) |
| **Secret management** | Bot tokens / API keys go directly in config | Gitignores the live `openclaw.json`; tracks only an `.example` template — same pattern as `.env` |
| **Multi-agent sandboxing** | Mentioned but not configured | Pre-configured agent sandbox defaults (isolated container per tool call, `network: none`, read-only root, 1 GB RAM cap, dropped capabilities) |
| **First-run experience** | Manual steps | `setup.sh` handles runtime detection, directory creation, token generation, image pull, and runtime config application in one command |

The core networking fix (socat sidecar + shared network namespace) is non-obvious and not documented upstream — it was found through debugging after the standard setup failed.

### Security posture

Most Docker-based OpenClaw setups skip hardening. This repo ships with it on by default:

| Control | Detail |
|---------|--------|
| **Clean security audit** | `0 critical · 0 warn` — `gateway.trustedProxies` auto-applied on first run; most setups leave this warning unresolved |
| **Secret management** | Live `data/config/openclaw.json` is gitignored (may contain bot tokens, passwords); only the `.example` template is tracked — same pattern as `.env` |
| **Per-agent sandbox** | Every agent's tool calls run in a dedicated ephemeral container: `capDrop: ALL`, `network: none`, read-only root filesystem, 1 GB RAM cap, 256 PID limit |
| **Loopback-only binding** | Docker: all host ports bound to `127.0.0.1` — not reachable from other machines. Podman on macOS: `0.0.0.0` (pasta networking requires it; `setup.sh` sets this automatically) |
| **Minimal attack surface** | socat containers use `alpine/socat` (no shell, no package manager); gateway runs as non-root `node` user |

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

# 3. Start (first time — applies all runtime config too)
./setup.sh

# Or for subsequent starts:
docker compose up -d

# 4. Verify
curl http://localhost:18789/healthz
# → {"ok":true,"status":"live"}

# 5. Open
open http://localhost:18789
```

## First login — device pairing

When you open the web UI for the first time, you'll see **"pairing required"**. This is expected — by design, OpenClaw requires every new client (browser, CLI) to be approved once, even with a valid gateway token, because Docker NAT makes the connection appear non-local.

Approving from inside the container forces a loopback connection that the gateway treats as trusted (no pairing gate):

```bash
# 1. Open the UI — this creates a pending pairing request
open http://127.0.0.1:18789

# 2. List pending requests — run AFTER opening the browser above
#    Look for a short UUID under "Pending" — that is the Request ID.
#    (The long hex IDs shown under "Paired" are already-approved devices, not usable here.)
docker compose exec openclaw-gateway sh -lc '
  node openclaw.mjs devices list \
  --url ws://127.0.0.1:18789 --token "$OPENCLAW_GATEWAY_TOKEN"
'

# 3. Approve using the Request ID (UUID) shown under Pending
docker compose exec openclaw-gateway sh -lc '
  node openclaw.mjs devices approve <REQUEST_ID> \
  --url ws://127.0.0.1:18789 --token "$OPENCLAW_GATEWAY_TOKEN"
'

# 4. Refresh the browser — connected.
```

The `--url ws://127.0.0.1:18789 --token "$OPENCLAW_GATEWAY_TOKEN"` flags are required: `--url` forces the connection via loopback (the gateway's "local" path, no pairing gate) and `--token` reads the token from the container's environment. The `sh -lc '...'` form ensures `$OPENCLAW_GATEWAY_TOKEN` expands inside the container.

Approved device identities are stored in `data/devices/paired.json` and persist as long as the gateway stays up — but re-pairing is needed after a full gateway restart (see [Troubleshooting](#troubleshooting)).

## File Layout

```
openclaw-docker/
├── docker-compose.yml              # All services
├── .env.example                    # Secrets template — copy to .env         [tracked]
├── .env                            # Your secrets                             [git-ignored]
├── setup.sh                        # First-run setup helper
├── data/
│   ├── config/
│   │   ├── openclaw.json.example   # Gateway config template                  [tracked]
│   │   └── openclaw.json           # Your gateway config — may hold secrets   [git-ignored]
│   ├── openclaw.json               # Runtime config store (written by CLI)    [git-ignored]
│   ├── workspace/                  # Agent files                              [git-ignored]
│   ├── identity/                   # Auth state                               [git-ignored]
│   └── sessions/                   # Session logs                             [git-ignored]
└── README.md
```

**Config file summary** — OpenClaw uses three config sources:

| File | Format | Written by | Purpose | Tracked? |
|------|--------|-----------|---------|----------|
| `data/config/openclaw.json` | JSON5 | You | Startup config: gateway mode/bind, agent sandbox defaults, channels (Telegram etc.) | **No** — may contain secrets like bot tokens |
| `data/config/openclaw.json.example` | JSON5 | This repo | Template for the above | Yes |
| `data/openclaw.json` | JSON | `config set` CLI | Runtime config: `trustedProxies` and other CLI-managed settings | No — updated with timestamp on every start |

`setup.sh` copies `openclaw.json.example → openclaw.json` on first run (same pattern as `.env.example → .env`).

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

| Host port | Env var | Purpose |
|-----------|---------|---------|
| `18789` | `OPENCLAW_PORT` | Web UI + WebSocket gateway |
| `18790` | `OPENCLAW_BRIDGE_PORT` | Bridge channel (desktop app pairing) |
| `18791` | `OPENCLAW_BROWSER_PORT` | Browser control UI |

**Docker:** all bound to `127.0.0.1` — local access only.
**Podman on macOS:** bound to `0.0.0.0` — pasta networking can't forward loopback-only ports. `setup.sh` sets this automatically.

**Browser extension relay (port 18792):** The gateway does not start its relay listener (`127.0.0.1:18792`) in a container deployment — it requires a local Chrome browser to be present. The browser extension will report "Relay not reachable" when running purely in Docker/Podman. See [issue #27924](https://github.com/openclaw/openclaw/issues/27924). Workaround: install and run OpenClaw natively on the host machine alongside the Docker gateway.

## Common Commands

Replace `docker compose` with `podman-compose` for Podman. All gateway-touching commands use
`sh -lc '...'` with `--url` and `--token` — this is required on both runtimes (see [First login](#first-login--device-pairing)).

```bash
# Start / stop
docker compose up -d
docker compose down

# Logs
docker compose logs -f openclaw-gateway

# Restart just the gateway (picks up JSON5 config changes)
docker compose restart openclaw-gateway

# Read / write runtime config (use this, not the JSON5 file, for trustedProxies etc.)
docker compose exec openclaw-gateway node openclaw.mjs config get <path>
docker compose exec openclaw-gateway node openclaw.mjs config set <path> <value>

# Security audit
docker compose exec openclaw-gateway sh -lc '
  node openclaw.mjs security audit \
  --url ws://127.0.0.1:18789 --token "$OPENCLAW_GATEWAY_TOKEN"
'

# Device pairing (see First login section above for full workflow)
docker compose exec openclaw-gateway sh -lc '
  node openclaw.mjs devices list \
  --url ws://127.0.0.1:18789 --token "$OPENCLAW_GATEWAY_TOKEN"
'
docker compose exec openclaw-gateway sh -lc '
  node openclaw.mjs devices approve <REQUEST_ID> \
  --url ws://127.0.0.1:18789 --token "$OPENCLAW_GATEWAY_TOKEN"
'
```

`setup.sh` prints these commands with the correct values filled in after startup.

## Key Config

OpenClaw uses two separate config systems:

### `data/config/openclaw.json` (JSON5 — startup config)

| Setting | Value | Why |
|---------|-------|-----|
| `gateway.mode` | `"local"` | Required for self-hosted — without this OpenClaw tries to connect to Claude.ai's remote gateway |
| `gateway.bind` | `"lan"` | Accepts port-forwarded connections, not just loopback |
| `gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback` | `true` | Required with non-loopback bind — uses HTTP Host header for origin check |
| `agents.defaults.sandbox.mode` | `"non-main"` | Each agent's tool calls run in isolated containers |

### Runtime config (via `config set` — stored in `data/openclaw.json`)

| Setting | Command | Why |
|---------|---------|-----|
| `gateway.trustedProxies` | `config set gateway.trustedProxies '["127.0.0.1","::1"]'` | Trusts the socat sidecar; clears the `trusted_proxies_missing` audit warning. Applied automatically by `setup.sh`. |
| `gateway.controlUi.allowedOrigins` | `config set gateway.controlUi.allowedOrigins '["http://127.0.0.1:18789","http://localhost:18789"]'` | Allows the Control UI to load from the standard host ports. Applied automatically by `setup.sh`. Add extra entries for LAN IPs or non-default ports. |

## Channels (WhatsApp / Telegram / Discord)

Use `exec` with `--url` for channel commands — `$OPENCLAW_GATEWAY_TOKEN` is read automatically from the container environment, so no separate `--token` flag is needed for gateway auth:

```bash
# Telegram
docker compose exec openclaw-gateway sh -lc '
  node openclaw.mjs channels add \
  --channel telegram --token "<BOT_TOKEN>" \
  --url ws://127.0.0.1:18789
'

# Discord
docker compose exec openclaw-gateway sh -lc '
  node openclaw.mjs channels add \
  --channel discord --token "<BOT_TOKEN>" \
  --url ws://127.0.0.1:18789
'
```

Get a Telegram token from **@BotFather** (`/newbot`). The CLI stores the token securely — you don't need to edit any config file for basic setup.

### Advanced Telegram config

For access control (`dmPolicy`, `allowFrom`) or group settings, add a `channels` block to `data/config/openclaw.json` after running the CLI command above:

> `data/config/openclaw.json` is **gitignored** — bot tokens and other secrets stay local and are never committed.

```json5
channels: {
  telegram: {
    enabled: true,
    botToken: "123456789:ABCDef...",   // from @BotFather

    // "pairing" = approve via web UI (default), "allowlist" = only listed IDs, "open" = anyone
    dmPolicy: "allowlist",
    allowFrom: ["YOUR_NUMERIC_USER_ID"],  // get yours from @userinfobot

    groupPolicy: "allowlist",
    groups: {
      "*": { requireMention: true },
    },

    streaming: "partial",
    ackReaction: "👀",
  },
},
```

Restart after editing: `docker compose restart openclaw-gateway`

Verify: `docker compose exec openclaw-gateway node openclaw.mjs status`

## Multiple Agents

One gateway manages all agents. Each agent automatically gets its own sandbox container for tool calls — no extra config needed. Create agents via the web UI at `http://localhost:18789`.

## Podman

`setup.sh` detects Podman automatically. A few differences from Docker worth knowing:

| Topic | Detail |
|-------|--------|
| **Port binding** | Podman on macOS uses `pasta` networking, which can't forward loopback-only (`127.0.0.1`) bindings. `setup.sh` sets `OPENCLAW_BIND=0.0.0.0` automatically. |
| **Sandbox mode** | The Podman Machine API socket (`*-api.sock`) can't be bind-mounted into VM containers. `setup.sh` detects this and sets `OPENCLAW_SANDBOX=0`. Sandbox can be re-enabled with TCP-based Podman access. |
| **CLI commands** | Use `exec` with `sh -lc '... --url ws://127.0.0.1:18789 --token "$OPENCLAW_GATEWAY_TOKEN"'` for all gateway-touching commands — same pattern as Docker, works reliably on both runtimes. |
| **Two-stage startup** | Gateway starts first; socat proxy containers start after it's healthy. `podman-compose` doesn't reliably respect `depends_on: service_healthy` for `network_mode: "service:X"`. |

## Troubleshooting

**"pairing required" (error 1008) on the Control UI**
This is expected — Docker NAT makes the browser appear as a non-loopback client, so OpenClaw requires one-time device pairing. `dangerouslyDisableDeviceAuth` does NOT fix this (confirmed upstream). Approve the device once from inside the container:

```bash
# List pending pairing requests
docker compose exec openclaw-gateway sh -lc '
  node openclaw.mjs devices list \
  --url ws://127.0.0.1:18789 --token "$OPENCLAW_GATEWAY_TOKEN"
'

# Approve using the Request ID from the list output
docker compose exec openclaw-gateway sh -lc '
  node openclaw.mjs devices approve <REQUEST_ID> \
  --url ws://127.0.0.1:18789 --token "$OPENCLAW_GATEWAY_TOKEN"
'
```

Refresh the browser — connected. See [First login — device pairing](#first-login--device-pairing) for the full walkthrough.

**"device signature expired" on the Control UI (after gateway restart)**
The browser's cached auth becomes stale when the gateway restarts — its stored signed challenge references server-side state that was reset. The device entry remains in the paired list; the browser just needs fresh credentials:

1. Open browser DevTools → **Application** → **Local Storage** → select `http://127.0.0.1:18789` → **Clear All** (or use *Clear site data*)
2. Refresh the tab — the UI now shows **"pairing required"** (creates a new pending request)
3. Re-approve (run `devices list` AFTER refreshing — only then will the pending UUID appear):

```bash
docker compose exec openclaw-gateway sh -lc '
  node openclaw.mjs devices list \
  --url ws://127.0.0.1:18789 --token "$OPENCLAW_GATEWAY_TOKEN"
'
docker compose exec openclaw-gateway sh -lc '
  node openclaw.mjs devices approve <REQUEST_ID> \
  --url ws://127.0.0.1:18789 --token "$OPENCLAW_GATEWAY_TOKEN"
'
```

This is a known upstream limitation — re-pairing is required after each full gateway restart.

**"origin not allowed" on the Control UI**
The gateway rejects WebSocket connections from origins not in its allowlist. `setup.sh` sets `gateway.controlUi.allowedOrigins` automatically and restarts the gateway to apply it. If you see this manually:
```bash
docker compose exec openclaw-gateway node openclaw.mjs config set gateway.controlUi.allowedOrigins '["http://127.0.0.1:18789","http://localhost:18789"]'
docker compose restart openclaw-gateway
```
If accessing from a non-default port or LAN IP, add that URL to `controlUi.allowedOrigins` in `data/config/openclaw.json`.

**`curl: (52) Empty reply from server`**
The socat proxy containers aren't running yet — the gateway binds to its own loopback (`127.0.0.1`) and socat is what bridges Docker's port-forwarding to it. Check that both proxy containers are up:
```bash
docker compose ps
docker compose up -d   # bring up any stopped services
```
Both `openclaw-proxy-ws` and `openclaw-proxy-browser` must be `Up (healthy)` for the gateway to be reachable from the host.

**`EACCES: permission denied, mkdir '/home/node/.openclaw/<dir>'`**
A new OpenClaw subdirectory couldn't be created. Since `./data` is mounted as the entire `.openclaw` dir, this shouldn't happen — check that the volume mount is correct in `docker-compose.yml`.

**Gateway shows "unreachable" in status**
Expected in a container — the gateway's self-probe can't verify external connectivity. As long as `curl http://localhost:18789/healthz` returns `{"ok":true}`, everything is working.

**Security audit still shows `trusted_proxies_missing`**
`gateway.trustedProxies` must be set via CLI, not the JSON5 file. Run:
```bash
docker compose exec openclaw-gateway node openclaw.mjs config set gateway.trustedProxies '["127.0.0.1","::1"]'
docker compose restart openclaw-gateway
```
`setup.sh` does this automatically on first run.

**Telegram bot not responding**
- Check the channel is active: `docker compose exec openclaw-gateway node openclaw.mjs status`
- Make sure you pressed **Start** in the Telegram chat (bots can't message you first)
- If `dmPolicy: "pairing"`, approve the device via `devices approve`
- Verify `botToken` is correct — copy it fresh from BotFather

**Port already in use**
Change `OPENCLAW_PORT` in `.env` and restart.

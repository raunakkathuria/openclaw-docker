# OpenClaw — Docker Setup (Sandboxed Multi-Agent)

**Architecture:** Single OpenClaw gateway + agent sandbox isolation.
Each agent's tool execution (shell commands, file reads/writes) runs inside its own short-lived Docker container — completely isolated from the gateway and from other agents.

```
Your Browser
    │
    ▼ :18789
┌─────────────────────────────────┐
│       openclaw-gateway          │  ← always running
│   (config/ + workspace/)        │
└────────┬────────────────────────┘
         │ spawns sandbox containers
         │ via Docker socket
    ┌────┴────┐   ┌────────────┐   ┌────────────┐
    │ agent-A │   │  agent-B   │   │  agent-C   │
    │ sandbox │   │  sandbox   │   │  sandbox   │
    │ (1g RAM │   │  (no net)  │   │  read-only │
    │  no net)│   │  capDrop:  │   │  filesystem│
    └─────────┘   │   ALL      │   └────────────┘
                  └────────────┘
```

## Quick Start

### 1. Clone / copy this folder to your machine

### 2. Run setup (first time only)

```bash
./setup.sh
```

The script will:
- Check Docker is running
- Create `config/` and `workspace/` directories
- Generate a `.env` from `.env.example` with a random gateway token
- Prompt you to add your `ANTHROPIC_API_KEY`
- Pull the OpenClaw image
- Start the gateway
- Launch the onboarding wizard

### 3. Open the web UI

```
http://127.0.0.1:18789
```

---

## Daily Operations

| Action | Command |
|--------|---------|
| Start | `docker compose up -d` |
| Stop | `docker compose down` |
| View logs | `docker compose logs -f openclaw-gateway` |
| Shell into gateway | `docker compose exec openclaw-gateway bash` |
| Run CLI command | `docker compose run --rm openclaw-cli <command>` |
| Check health | `curl -fsS http://127.0.0.1:18789/healthz` |

---

## Sandbox Explained

Sandbox mode is enabled by default (`OPENCLAW_SANDBOX=1`).

When an agent calls a tool (e.g. runs a shell command or reads a file), the gateway spawns a fresh Docker container to execute it. That container:

- Has **no network access** (`network: none`) — can't make outbound requests
- Has a **read-only root filesystem** — can't tamper with the host
- Has **all Linux capabilities dropped** (`capDrop: ALL`)
- Is **memory-limited to 1 GB** and **process-limited to 256 PIDs**
- Is **destroyed** after the tool call completes

This means even if an agent goes rogue or gets confused, its blast radius is limited to its own sandbox container — your host and other agents are not affected.

Configuration lives in `config/openclaw.json` under `agents.defaults.sandbox`.

---

## File Layout

```
openclaw-docker/
├── docker-compose.yml      # All services
├── .env.example            # Template — copy to .env
├── .env                    # Your secrets (git-ignored)
├── setup.sh                # First-time setup script
├── config/
│   └── openclaw.json       # Agent + sandbox + gateway config
└── workspace/              # Agent memory, files, session logs
```

**Important:** Add `.env` and `workspace/` to your `.gitignore` if you put this in a repo.

---

## Multiple Agents

You don't need to run multiple gateways for multiple agents. One gateway manages all your agents. Each agent automatically gets its own sandbox when it calls tools.

To create a new agent, use the web UI at `http://127.0.0.1:18789` → Agents → New Agent.

If you want truly separate gateways (e.g. different API key budgets, completely different configs), duplicate the compose service with different ports and config directories — see the "Advanced: Multiple Gateways" section below.

---

## Channels (WhatsApp / Telegram / Discord)

```bash
# WhatsApp
docker compose run --rm openclaw-cli channels login

# Telegram
docker compose run --rm openclaw-cli channels add --channel telegram --token "<BOT_TOKEN>"

# Discord
docker compose run --rm openclaw-cli channels add --channel discord --token "<BOT_TOKEN>"
```

---

## Browser Agent Support (optional)

Uncomment the `browserless` service in `docker-compose.yml` and start it:

```bash
docker compose --profile browserless up -d
```

Then configure an agent to use `ws://browserless:3000` for web browsing. This offloads Chrome from the main gateway container.

---

## Advanced: Multiple Gateways

For strict budget/config separation, you can run multiple gateway instances. Add to `docker-compose.yml`:

```yaml
  openclaw-gateway-ops:
    image: ${OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw:latest}
    container_name: openclaw-gateway-ops
    restart: unless-stopped
    environment:
      OPENCLAW_GATEWAY_TOKEN: ${OPENCLAW_GATEWAY_TOKEN_OPS}
      ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY_OPS}
      OPENCLAW_SANDBOX: "1"
    volumes:
      - ./config-ops:/home/node/.openclaw/config
      - ./workspace-ops:/home/node/.openclaw/workspace
      - /var/run/docker.sock:/var/run/docker.sock
    ports:
      - "127.0.0.1:18791:18789"
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:18789/healthz"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 45s
```

Each gateway gets its own port, its own config directory, and its own API key.

---

## Troubleshooting

**Gateway OOM (exit 137)**
Increase Docker Desktop memory limit to at least 2–4 GB in Settings → Resources.

**Permission error on config/workspace**
```bash
sudo chown -R 1000:1000 config workspace
```

**Sandbox containers not spawning (Docker Desktop Mac)**
The Docker socket path may differ. Set in `.env`:
```
DOCKER_SOCKET=/Users/<you>/.docker/run/docker.sock
```

**Pairing failed / gateway unreachable**
```bash
docker compose run --rm openclaw-cli config set gateway.mode local
docker compose run --rm openclaw-cli config set gateway.bind lan
docker compose restart openclaw-gateway
```

**Approve a paired device**
```bash
docker compose run --rm openclaw-cli devices list
docker compose run --rm openclaw-cli devices approve <ID>
```

---

## References

- [OpenClaw Docker docs](https://docs.openclaw.ai/install/docker)
- [Official docker-compose.yml](https://github.com/openclaw/openclaw/blob/main/docker-compose.yml)
- [katitusi/clawbot](https://github.com/katitusi/clawbot) — production hardening reference
- [joshua5201/openclaw-docker-compose](https://github.com/joshua5201/openclaw-docker-compose) — isolated sandbox setup
- [Docker blog: OpenClaw sandboxes](https://www.docker.com/blog/run-openclaw-securely-in-docker-sandboxes/)

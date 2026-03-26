#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# OpenClaw Docker/Podman Setup Script
# Handles first-time setup: env generation, image pull, onboarding wizard.
# Safe to re-run — existing config and .env are not overwritten.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${BLUE}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error()   { echo -e "${RED}[ERR]${RESET}  $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}${CYAN}── $* ──${RESET}"; }

# ── Detect runtime: Podman or Docker ─────────────────────────────────────────
step "Detecting container runtime"

RUNTIME=""
COMPOSE_CMD=""

if command -v podman &>/dev/null && podman info &>/dev/null 2>&1; then
  RUNTIME="podman"
  # Prefer podman-compose if available, otherwise use podman compose
  if command -v podman-compose &>/dev/null; then
    COMPOSE_CMD="podman-compose"
  else
    COMPOSE_CMD="podman compose"
  fi
  # Silence podman-compose provider warning
  export PODMAN_COMPOSE_WARNING_LOGS=0
  success "Podman detected — using $COMPOSE_CMD"
  # Warn if Podman Machine has less than 3 GB RAM — the gateway needs ~1 GB V8 heap
  # and the VM can OOM on the first UI connection with the default 2 GB allocation.
  _vm_mem_mb=$(podman machine inspect --format '{{.Resources.Memory}}' 2>/dev/null || echo 0)
  if [[ $_vm_mem_mb -gt 0 && $_vm_mem_mb -lt 3072 ]]; then
    warn "Podman Machine has ${_vm_mem_mb} MB RAM — OpenClaw gateway needs ~1 GB heap."
    warn "Increase to at least 4 GB to avoid out-of-memory crashes:"
    warn "  podman machine stop && podman machine set --memory 4096 && podman machine start"
  fi
elif command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
  RUNTIME="docker"
  if docker compose version &>/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
  else
    error "Docker Compose v2 not found. Update Docker Desktop or install the 'docker-compose-plugin'."
  fi
  success "Docker detected — using $COMPOSE_CMD"
else
  error "Neither Docker nor Podman is running. Install one from:
  Docker:  https://docs.docker.com/get-docker/
  Podman:  https://podman.io/getting-started/installation"
fi

# ── Directory layout ──────────────────────────────────────────────────────────
step "Creating directory structure"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

mkdir -p data/config data/workspace data/canvas
# Restrict state dir to owner-only (clears OpenClaw security audit warning)
chmod 700 data

# Fix ownership for the node user inside the container (uid 1000).
# Podman rootless maps the container's uid 1000 to a subuid on the host —
# in that case chown isn't needed and we skip it silently.
if [[ "$RUNTIME" == "docker" ]]; then
  if [[ "$(id -u)" -eq 0 ]]; then
    chown -R 1000:1000 config workspace canvas
  else
    chown -R 1000:1000 config workspace canvas 2>/dev/null || \
      warn "Could not chown directories to uid 1000. Run: sudo chown -R 1000:1000 config workspace canvas"
  fi
fi

# Copy gateway config template on first run.
# data/config/openclaw.json is gitignored so secrets (e.g. Telegram botToken)
# never end up in the repo. The .example file is the tracked template.
if [[ -f data/config/openclaw.json ]]; then
  info "data/config/openclaw.json already exists — skipping (delete to regenerate)"
else
  cp data/config/openclaw.json.example data/config/openclaw.json
  success "data/config/openclaw.json created from example"
  echo ""
  echo -e "  ${YELLOW}NOTE:${RESET} Edit ${BOLD}data/config/openclaw.json${RESET} to add channels (Telegram etc.)."
  echo -e "  It is gitignored — secrets in it will not be committed."
  echo ""
fi

success "data/config/, data/workspace/, and data/canvas/ ready"

# ── .env setup ────────────────────────────────────────────────────────────────
step "Environment configuration"

if [[ -f .env ]]; then
  info ".env already exists — skipping generation (delete it to regenerate)"
else
  cp .env.example .env

  # Auto-generate a secure gateway token
  if command -v openssl &>/dev/null; then
    TOKEN=$(openssl rand -hex 32)
  else
    TOKEN=$(head -c 32 /dev/urandom | xxd -p | tr -d '\n')
  fi
  # Works on both macOS (BSD sed) and Linux (GNU sed)
  sed -i.bak "s/^OPENCLAW_GATEWAY_TOKEN=$/OPENCLAW_GATEWAY_TOKEN=${TOKEN}/" .env
  rm -f .env.bak

  success ".env created with auto-generated gateway token"
  echo ""
  echo -e "  ${YELLOW}ACTION REQUIRED:${RESET} Open ${BOLD}.env${RESET} and set your ${BOLD}ANTHROPIC_API_KEY${RESET}"
  echo ""
  read -rp "  Press Enter after you've set your API key... "
fi

# Validate key fields
# shellcheck source=.env
source .env
[[ -z "${ANTHROPIC_API_KEY:-}" ]] && error "ANTHROPIC_API_KEY is not set in .env"
[[ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]] && error "OPENCLAW_GATEWAY_TOKEN is not set in .env"
success "Environment variables validated"

# ── Container socket check ────────────────────────────────────────────────────
step "Verifying container socket for sandbox mode"

if [[ "$RUNTIME" == "podman" ]]; then
  # Detect Podman's Docker-compatible socket.
  # NOTE: the Podman Machine API socket (*-api.sock / podman-machine-default-api.sock)
  # is only for machine management — it cannot be bind-mounted into containers and
  # causes "statfs: operation not supported" on macOS.  Skip it and look for the
  # Docker-compatible socket instead.
  PODMAN_SOCK_CANDIDATES=(
    "$HOME/.local/share/containers/podman/machine/podman-machine-default/podman.sock"
    "$HOME/.local/share/containers/podman/machine/podman.sock"
    "$HOME/.local/share/containers/podman/machine/qemu/podman.sock"
    "/run/user/$(id -u)/podman/podman.sock"
    "/var/run/podman/podman.sock"
    "/var/run/docker.sock"
  )
  DOCKER_SOCKET="${DOCKER_SOCKET:-}"
  # Reset if .env still holds the API-socket path from a previous run
  [[ "$DOCKER_SOCKET" == *"api.sock"* ]] && DOCKER_SOCKET=""
  if [[ -z "$DOCKER_SOCKET" ]]; then
    for candidate in "${PODMAN_SOCK_CANDIDATES[@]}"; do
      if [[ -S "$candidate" ]]; then
        DOCKER_SOCKET="$candidate"
        break
      fi
    done
  fi
  if [[ -S "${DOCKER_SOCKET:-}" ]]; then
    # On macOS, Podman runs containers in a Linux VM (applehv / qemu).
    # The Podman Machine API socket lives in $TMPDIR (/var/folders/…/T/).
    # Socket files in that location CANNOT be bind-mounted into VM containers:
    # virtio-fs only shares regular files and directories, not special files.
    # Podman reports this as "statfs … operation not supported" and refuses to
    # start the container.
    #
    # Workaround: swap in a dummy regular file as the bind-mount source and
    # disable sandbox mode (agents won't run in isolated containers, but the
    # gateway itself will start correctly).
    _resolved="$(readlink -f "$DOCKER_SOCKET" 2>/dev/null || echo "$DOCKER_SOCKET")"
    if [[ "$(uname)" == "Darwin" ]] && \
       { [[ "$_resolved" == /private/var/folders/* ]] || [[ "$_resolved" == /var/folders/* ]]; }; then
      warn "Podman API socket is in macOS temp dir and cannot be bind-mounted into the VM."
      warn "Disabling sandbox mode (OPENCLAW_SANDBOX=0) — agents will not run in isolated containers."
      # Create a placeholder regular file; virtio-fs can share it, avoiding the statfs error.
      touch ./data/docker.sock
      DOCKER_SOCKET="$(pwd)/data/docker.sock"
      # Disable sandbox in .env
      if grep -q "^OPENCLAW_SANDBOX=" .env; then
        sed -i.bak "s|^OPENCLAW_SANDBOX=.*|OPENCLAW_SANDBOX=0|" .env && rm -f .env.bak
      else
        echo "OPENCLAW_SANDBOX=0" >> .env
      fi
    else
      success "Podman socket found at $DOCKER_SOCKET"
    fi
    # Persist into .env so docker-compose.yml picks it up
    if ! grep -q "^DOCKER_SOCKET=" .env; then
      echo "DOCKER_SOCKET=$DOCKER_SOCKET" >> .env
    else
      sed -i.bak "s|^DOCKER_SOCKET=.*|DOCKER_SOCKET=$DOCKER_SOCKET|" .env
      rm -f .env.bak
    fi
    # Re-source so the variable is available below
    source .env
  else
    warn "Podman socket not found automatically. Sandbox mode may not work."
    if [[ "$(uname)" == "Darwin" ]]; then
      warn "Start the Podman machine socket with:  podman machine start"
    else
      warn "Enable the Podman socket with:  systemctl --user start podman.socket"
    fi
    warn "Then set DOCKER_SOCKET in .env to the socket path."
  fi
else
  DOCKER_SOCKET="${DOCKER_SOCKET:-/var/run/docker.sock}"
  if [[ -S "$DOCKER_SOCKET" ]]; then
    success "Docker socket found at $DOCKER_SOCKET"
  else
    warn "Docker socket not found at $DOCKER_SOCKET"
    if [[ "$(uname)" == "Darwin" ]]; then
      warn "On Docker Desktop (Mac), try: DOCKER_SOCKET=\$HOME/.docker/run/docker.sock"
    else
      warn "Ensure the Docker daemon is running and your user is in the 'docker' group:"
      warn "  sudo usermod -aG docker \$USER  (then log out and back in)"
    fi
  fi
fi

# ── Podman/macOS: set bind address ────────────────────────────────────────────
# Podman rootless on macOS uses pasta networking, which cannot forward ports
# bound to 127.0.0.1. Switch to 0.0.0.0 so the VM network stack can reach the
# host ports. Docker users keep 127.0.0.1 (local-only, no change needed).
if [[ "$RUNTIME" == "podman" ]] && [[ "$(uname)" == "Darwin" ]]; then
  if grep -q "^OPENCLAW_BIND=" .env; then
    sed -i.bak "s|^OPENCLAW_BIND=.*|OPENCLAW_BIND=0.0.0.0|" .env && rm -f .env.bak
  else
    echo "OPENCLAW_BIND=0.0.0.0" >> .env
  fi
  source .env
  info "OPENCLAW_BIND set to 0.0.0.0 (Podman/macOS pasta networking)"
fi

# ── Pull images ───────────────────────────────────────────────────────────────
step "Pulling OpenClaw image"

OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw:latest}"
info "Pulling $OPENCLAW_IMAGE ..."
$RUNTIME pull "$OPENCLAW_IMAGE"
success "Image ready"

step "Preparing sandbox image"
SANDBOX_IMAGE="ghcr.io/openclaw/openclaw-sandbox:latest"
if $RUNTIME pull "$SANDBOX_IMAGE" 2>/dev/null; then
  success "Sandbox image ready"
else
  warn "Could not pull $SANDBOX_IMAGE — will be built on first agent run"
fi

# ── Start all services ────────────────────────────────────────────────────────
step "Starting OpenClaw services"

# Check that the gateway ports are not already held by an *external* process.
# gvproxy / pasta are Podman's own port-forwarding daemons — --force-recreate
# handles rebinding those, so we skip them here.
for _port in "${OPENCLAW_PORT:-18789}" "${OPENCLAW_BRIDGE_PORT:-18790}" "${OPENCLAW_BROWSER_PORT:-18791}"; do
  _pid=$(lsof -iTCP:"$_port" -sTCP:LISTEN -t 2>/dev/null || true)
  if [[ -n "$_pid" ]]; then
    _name=$(ps -p "$_pid" -o comm= 2>/dev/null || echo "unknown")
    # Skip Podman's / Docker's own port-forwarding processes (match by basename
    # since macOS ps -o comm= may return the full path)
    _basename="${_name##*/}"
    [[ "$_basename" == "gvproxy" || "$_basename" == "pasta" || "$_basename" == "vpnkit" ]] && continue
    _cwd=$(lsof -p "$_pid" 2>/dev/null | awk 'NR==2{print $NF}')
    error "Port $_port is already in use by '$_name' (PID $_pid, cwd: $_cwd).
  Stop that process before running setup, e.g.:  kill $_pid"
  fi
done

# Suppress podman-compose provider banner
export PODMAN_COMPOSE_WARNING_LOGS=0

# Docker: start all services at once — depends_on: service_healthy handles ordering.
# Podman: start only the gateway first; Podman compose doesn't reliably respect
# depends_on ordering for network_mode: "service:X", so we wait for the gateway
# to become healthy before starting the socat proxy containers.
if [[ "$RUNTIME" == "podman" ]]; then
  # Podman: start gateway first — compose doesn't reliably respect
  # depends_on: service_healthy ordering for network_mode: "service:X",
  # so the socat proxy containers fail with "no such container" if all
  # services are started together.
  $COMPOSE_CMD up -d --force-recreate openclaw-gateway
else
  $COMPOSE_CMD up -d
fi
info "Waiting for gateway to become healthy (up to 120s)..."

# Strategy: poll the Docker/Podman health status set by the compose healthcheck
# (wget /healthz). This is the same approach used after the config restart below,
# and avoids relying on a specific log line that may change between releases.
MAX_WAIT=120
WAITED=0
READY=0
CONTAINER_NAME="openclaw-gateway"

while [[ $WAITED -lt $MAX_WAIT ]]; do
  _hs=$($RUNTIME inspect --format '{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")
  if [[ "$_hs" == "healthy" ]]; then
    READY=1
    break
  fi
  # Bail out early if the container stopped
  _cs=$($RUNTIME inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "missing")
  if [[ "$_cs" == "exited" || "$_cs" == "missing" ]]; then
    echo ""
    error "Gateway container exited unexpectedly. Logs:
$($COMPOSE_CMD logs --tail=30 openclaw-gateway 2>/dev/null)"
  fi
  sleep 3
  WAITED=$((WAITED + 3))
  echo -n "."
done
echo ""

if [[ $READY -eq 0 ]]; then
  warn "Could not confirm gateway startup within ${MAX_WAIT}s."
  warn "It may still be starting. Check: $COMPOSE_CMD logs openclaw-gateway"
  warn "If it's running, open http://127.0.0.1:${OPENCLAW_PORT:-18789} to continue."
  exit 0
fi

success "Gateway is ready"

# Podman: now start the socat proxy containers — gateway is confirmed healthy
# so they can successfully join its network namespace.
# Name them explicitly to avoid recreating (and briefly disrupting) the gateway.
if [[ "$RUNTIME" == "podman" ]]; then
  $COMPOSE_CMD up -d openclaw-proxy-ws openclaw-proxy-browser
fi

# ── Apply runtime config ──────────────────────────────────────────────────────
# gateway.trustedProxies CANNOT be set in openclaw.json (JSON5) — OpenClaw
# ignores it there. It must be written to the runtime config store via the CLI.
# controlUi.allowedOrigins CAN be in openclaw.json but we sync it here too so
# the correct port is always current even when OPENCLAW_PORT was changed.
# Both settings take effect after the gateway restart below.
step "Applying runtime config"

_port="${OPENCLAW_PORT:-18789}"
_origins='["http://127.0.0.1:'"$_port"'","http://localhost:'"$_port"'"]'

$COMPOSE_CMD exec openclaw-gateway \
  node openclaw.mjs config set gateway.trustedProxies '["127.0.0.1","::1"]' \
  && success "gateway.trustedProxies set" \
  || warn "Could not apply gateway.trustedProxies — run manually:
    $COMPOSE_CMD exec openclaw-gateway node openclaw.mjs config set gateway.trustedProxies '[\"127.0.0.1\",\"::1\"]'"

$COMPOSE_CMD exec openclaw-gateway \
  node openclaw.mjs config set gateway.controlUi.allowedOrigins "$_origins" \
  && success "gateway.controlUi.allowedOrigins set to $_origins" \
  || warn "Could not set allowedOrigins — if the web UI shows 'origin not allowed', add your URL to controlUi.allowedOrigins in data/config/openclaw.json"

# Restart gateway and socat proxy containers so the above config takes effect.
# Socat containers share the gateway's network namespace — after a gateway restart
# the namespace reference becomes stale. Stop them first, restart the gateway,
# then recreate them so they bind to the fresh namespace. This applies to both
# Docker and Podman (Docker compose restart can also produce a new namespace).
step "Restarting gateway to apply config"
$COMPOSE_CMD stop openclaw-proxy-browser openclaw-proxy-ws 2>/dev/null || true
# Clear stale device signatures before restarting — after restart they are
# invalid anyway, and clearing now prevents "device signature expired" in the
# browser (replaced with the cleaner "pairing required" flow).
$COMPOSE_CMD exec openclaw-gateway \
  node openclaw.mjs devices clear --yes --paired 2>/dev/null \
  && info "Cleared paired device signatures (re-pairing required after restart)" \
  || true
$COMPOSE_CMD restart openclaw-gateway
info "Waiting for gateway to restart..."
_waited=0
while [[ $_waited -lt 60 ]]; do
  _hs=$($RUNTIME inspect --format '{{.State.Health.Status}}' openclaw-gateway 2>/dev/null || echo "unknown")
  [[ "$_hs" == "healthy" ]] && break
  sleep 3; _waited=$((_waited + 3)); echo -n "."
done
echo ""
$COMPOSE_CMD up -d openclaw-proxy-ws openclaw-proxy-browser
success "Gateway restarted — runtime config active"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║  OpenClaw is up and running!             ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  Web UI:   ${CYAN}http://127.0.0.1:${OPENCLAW_PORT:-18789}${RESET}"
echo -e "  Sandbox:  ${GREEN}enabled${RESET} — each agent's tool calls run in an isolated container"
echo ""
_port="${OPENCLAW_PORT:-18789}"
echo -e "  ${BOLD}Device pairing (required after each setup run):${RESET}"
echo ""
echo -e "  1. Open: ${CYAN}http://127.0.0.1:${_port}${RESET}  (you'll see \"pairing required\")"
echo -e "  2. ${BOLD}$COMPOSE_CMD exec openclaw-gateway node openclaw.mjs devices list${RESET}"
echo -e "     Look for the UUID under Pending — that is the Request ID."
echo -e "     If multiple UUIDs appear, approve any one — extras expire automatically."
echo -e "  3. ${BOLD}$COMPOSE_CMD exec openclaw-gateway node openclaw.mjs devices approve <REQUEST_ID>${RESET}"
echo -e "  4. Refresh the browser — connected."
echo ""
_exec="$COMPOSE_CMD exec openclaw-gateway"
echo -e "  ${BOLD}Common commands:${RESET}"
echo -e "    $COMPOSE_CMD up -d                                         # start"
echo -e "    $COMPOSE_CMD down                                          # stop"
echo -e "    $COMPOSE_CMD logs -f openclaw-gateway                      # stream logs"
echo -e "    $_exec node openclaw.mjs security audit               # security check"
echo -e "    $_exec node openclaw.mjs channels add \\                # add Telegram"
echo -e "      --channel telegram --token \"<BOT_TOKEN>\""
echo ""

# ── Final reachability check ──────────────────────────────────────────────────
# Catches cases where socat proxies are bound to a stale network namespace:
# - Gateway OOM-crashed and auto-restarted during setup, or
# - docker/podman compose restart produced a new network namespace.
# Socat accepts TCP connections but can't forward to the new gateway loopback,
# causing "empty reply from server".
sleep 2
if ! curl -sf "http://127.0.0.1:${OPENCLAW_PORT:-18789}/healthz" >/dev/null 2>&1; then
  warn "Gateway health endpoint not reachable from the host."
  warn "Restarting socat proxy containers to recover namespace binding..."
  $COMPOSE_CMD up -d openclaw-proxy-ws openclaw-proxy-browser
  sleep 2
  if curl -sf "http://127.0.0.1:${OPENCLAW_PORT:-18789}/healthz" >/dev/null 2>&1; then
    success "Gateway reachable — socat proxies recovered."
  else
    warn "Still not reachable. Check logs: $COMPOSE_CMD logs openclaw-gateway"
  fi
fi

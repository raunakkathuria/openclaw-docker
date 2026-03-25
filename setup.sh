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

success "config/, workspace/, and canvas/ ready"

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
  # Detect Podman's Docker-compatible socket
  PODMAN_SOCK_CANDIDATES=(
    "$HOME/.local/share/containers/podman/machine/podman.sock"
    "$HOME/.local/share/containers/podman/machine/qemu/podman.sock"
    "/run/user/$(id -u)/podman/podman.sock"
    "/var/run/podman/podman.sock"
  )
  DOCKER_SOCKET="${DOCKER_SOCKET:-}"
  if [[ -z "$DOCKER_SOCKET" ]]; then
    for candidate in "${PODMAN_SOCK_CANDIDATES[@]}"; do
      if [[ -S "$candidate" ]]; then
        DOCKER_SOCKET="$candidate"
        break
      fi
    done
  fi
  if [[ -S "${DOCKER_SOCKET:-}" ]]; then
    success "Podman socket found at $DOCKER_SOCKET"
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
    warn "Start the Podman machine socket with:  podman machine start"
    warn "Then set DOCKER_SOCKET in .env to the socket path."
  fi
else
  DOCKER_SOCKET="${DOCKER_SOCKET:-/var/run/docker.sock}"
  if [[ -S "$DOCKER_SOCKET" ]]; then
    success "Docker socket found at $DOCKER_SOCKET"
  else
    warn "Docker socket not found at $DOCKER_SOCKET"
    warn "On Docker Desktop (Mac), try: DOCKER_SOCKET=\$HOME/.docker/run/docker.sock"
  fi
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

# ── Start gateway ─────────────────────────────────────────────────────────────
step "Starting OpenClaw gateway"

# Suppress podman-compose provider banner
export PODMAN_COMPOSE_WARNING_LOGS=0

$COMPOSE_CMD up -d openclaw-gateway
info "Waiting for gateway to become healthy (up to 120s)..."

# Strategy: watch container logs for the "listening" line rather than
# hitting the HTTP endpoint — more reliable across Docker and Podman,
# and avoids curl-not-found issues inside the container.
MAX_WAIT=120
WAITED=0
READY=0
CONTAINER_NAME="openclaw-gateway"

while [[ $WAITED -lt $MAX_WAIT ]]; do
  # Check for the listening message in logs
  if $COMPOSE_CMD logs openclaw-gateway 2>/dev/null | grep -q "listening on ws://"; then
    READY=1
    break
  fi
  # Also check that the container hasn't exited
  if [[ "$RUNTIME" == "podman" ]]; then
    STATUS=$($RUNTIME inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "missing")
  else
    STATUS=$($RUNTIME inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "missing")
  fi
  if [[ "$STATUS" == "exited" || "$STATUS" == "missing" ]]; then
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
  warn "Could not confirm gateway startup via logs within ${MAX_WAIT}s."
  warn "It may still be starting. Check: $COMPOSE_CMD logs openclaw-gateway"
  warn "If it's running, you can proceed manually:"
  warn "  $COMPOSE_CMD run --rm openclaw-cli onboard"
  exit 0
fi

success "Gateway is ready"

# ── Apply runtime config (trustedProxies) ─────────────────────────────────────
# gateway.trustedProxies cannot be set in openclaw.json (JSON5) — OpenClaw
# ignores it there. It must be written to the runtime config store via the CLI.
# Trusting 127.0.0.1 / ::1 tells the gateway that the socat sidecar (which
# forwards Docker port traffic to the loopback listener) is a known proxy,
# clearing the "trusted_proxies_missing" security audit warning.
step "Applying runtime config"

$COMPOSE_CMD exec openclaw-gateway \
  node openclaw.mjs config set gateway.trustedProxies '["127.0.0.1","::1"]' \
  && success "gateway.trustedProxies set" \
  || warn "Could not apply gateway.trustedProxies — run manually after startup:
    $COMPOSE_CMD exec openclaw-gateway node openclaw.mjs config set gateway.trustedProxies '[\"127.0.0.1\",\"::1\"]'"

# ── Onboarding wizard ─────────────────────────────────────────────────────────
step "Running onboarding wizard"

info "The wizard will walk you through pairing a device and configuring your first agent."
$COMPOSE_CMD run --rm openclaw-cli onboard

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║  OpenClaw is up and running!             ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  Web UI:      ${CYAN}http://127.0.0.1:${OPENCLAW_PORT:-18789}${RESET}"
echo -e "  Sandbox:     ${GREEN}enabled${RESET} (each agent isolated in its own container)"
echo ""
echo -e "  ${BOLD}Useful commands (replace 'podman-compose' with 'docker compose' if using Docker):${RESET}"
echo -e "    $COMPOSE_CMD up -d                          # start"
echo -e "    $COMPOSE_CMD down                           # stop"
echo -e "    $COMPOSE_CMD logs -f openclaw-gateway       # stream logs"
echo -e "    $COMPOSE_CMD run --rm openclaw-cli <cmd>    # run CLI command"
echo -e "    $RUNTIME exec -it openclaw-gateway bash     # shell into gateway"
echo ""
echo -e "  ${BOLD}Approve a paired device:${RESET}"
echo -e "    $COMPOSE_CMD run --rm openclaw-cli devices list"
echo -e "    $COMPOSE_CMD run --rm openclaw-cli devices approve <ID>"
echo ""

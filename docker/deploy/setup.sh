#!/usr/bin/env bash
#
# One-command setup for an always-on, public, HTTPS Paperclip instance.
#
# Run this on a fresh Ubuntu VPS after you have:
#   1. pointed a domain's DNS A record at this server's IP
#   2. cloned the repo and cd'd into docker/deploy/
#
# It will:
#   - install Docker (if missing)
#   - generate strong secrets (only the first time)
#   - write .env
#   - open the firewall for HTTP/HTTPS (if ufw is present)
#   - build and start the stack
#
# Usage:
#   ./setup.sh                                  # interactive (prompts for domain + email)
#   ./setup.sh paperclip.example.com you@x.com  # non-interactive
#   PAPERCLIP_DOMAIN=... ACME_EMAIL=... ./setup.sh
#
# Re-running is safe: existing secrets in .env are preserved.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE="$SCRIPT_DIR/.env"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.prod.yml"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
err() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$1" >&2; exit 1; }

# --- Read existing .env values (so re-runs keep stable secrets) ----------------
get_env() {
  # get_env KEY  -> prints current value from .env, or empty
  [ -f "$ENV_FILE" ] || return 0
  sed -n "s/^$1=//p" "$ENV_FILE" | head -n1
}

DOMAIN="${1:-${PAPERCLIP_DOMAIN:-$(get_env PAPERCLIP_DOMAIN)}}"
EMAIL="${2:-${ACME_EMAIL:-$(get_env ACME_EMAIL)}}"
BETTER_AUTH_SECRET="$(get_env BETTER_AUTH_SECRET)"
POSTGRES_PASSWORD="$(get_env POSTGRES_PASSWORD)"
OPENAI_API_KEY="${OPENAI_API_KEY:-$(get_env OPENAI_API_KEY)}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-$(get_env ANTHROPIC_API_KEY)}"

# --- Prompt for anything still missing ----------------------------------------
if [ -z "$DOMAIN" ]; then
  read -rp "Domain that points at this server (e.g. paperclip.example.com): " DOMAIN
fi
[ -n "$DOMAIN" ] || err "A domain is required."

if [ -z "$EMAIL" ]; then
  read -rp "Email for the TLS certificate (Let's Encrypt): " EMAIL
fi
[ -n "$EMAIL" ] || err "An email is required for TLS registration."

# --- Install Docker if needed -------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker..."
  curl -fsSL https://get.docker.com | sh
else
  log "Docker already installed."
fi

if ! docker compose version >/dev/null 2>&1; then
  err "Docker Compose plugin not found. Install Docker from https://get.docker.com and re-run."
fi

# --- Generate secrets on first run only ---------------------------------------
gen() { openssl rand -hex "$1"; }
if [ -z "$BETTER_AUTH_SECRET" ]; then
  log "Generating BETTER_AUTH_SECRET..."
  BETTER_AUTH_SECRET="$(gen 32)"
fi
if [ -z "$POSTGRES_PASSWORD" ]; then
  log "Generating POSTGRES_PASSWORD..."
  POSTGRES_PASSWORD="$(gen 24)"
fi

# --- Write .env ---------------------------------------------------------------
log "Writing $ENV_FILE"
umask 077
cat > "$ENV_FILE" <<EOF
PAPERCLIP_DOMAIN=$DOMAIN
ACME_EMAIL=$EMAIL
BETTER_AUTH_SECRET=$BETTER_AUTH_SECRET
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
EOF
[ -n "$OPENAI_API_KEY" ] && echo "OPENAI_API_KEY=$OPENAI_API_KEY" >> "$ENV_FILE"
[ -n "$ANTHROPIC_API_KEY" ] && echo "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY" >> "$ENV_FILE"

# --- Open firewall (best effort) ----------------------------------------------
if command -v ufw >/dev/null 2>&1; then
  log "Opening firewall ports 80/443 (and OpenSSH)..."
  ufw allow 80 >/dev/null 2>&1 || true
  ufw allow 443 >/dev/null 2>&1 || true
  ufw allow OpenSSH >/dev/null 2>&1 || true
fi

# --- Build and start ----------------------------------------------------------
log "Building and starting the stack (first build can take several minutes)..."
docker compose -f "$COMPOSE_FILE" up -d --build

printf '\n\033[1;32mDone.\033[0m Paperclip is starting at: https://%s\n' "$DOMAIN"
cat <<EOF

Next steps:
  1. Wait ~1 minute for the build to finish and the TLS certificate to be issued.
     Watch logs:  docker compose -f $COMPOSE_FILE logs -f

  2. Create your admin account (public mode requires this one-time invite):

       docker compose -f $COMPOSE_FILE exec paperclip \\
         node --import ./server/node_modules/tsx/dist/loader.mjs \\
         cli/src/index.ts auth bootstrap-ceo

     Open the printed URL in your browser to claim the instance.

Full guide: doc/DEPLOY-VPS.md
EOF

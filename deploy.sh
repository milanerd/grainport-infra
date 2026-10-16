#!/usr/bin/env bash
#
# GrainPort deploy script — API (Docker) + Web (Expo static export + rsync) + Caddy.
#
# Usage:
#   ./deploy.sh <target> <environment>
#
#   target:      api | web | caddy | all
#   environment: staging | production
#
# Examples:
#   ./deploy.sh api production
#   ./deploy.sh web staging
#   ./deploy.sh caddy production
#   ./deploy.sh all production
#
# Requires:
#   - SSH access to the Hetzner VPS (key + host below)
#   - Docker + docker compose on the VPS
#   - Node/npm + Expo CLI locally (for web builds)
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — edit these to match the server layout
# ---------------------------------------------------------------------------
SSH_KEY="${SSH_KEY:-$HOME/.ssh/hetzner}"
SSH_HOST="${SSH_HOST:-root@167.233.100.68}"

# Remote base directory (adjust if your server uses a different root)
REMOTE_BASE="${REMOTE_BASE:-/srv/grainport}"

# Remote directories (match the server Caddy config)
#   API  staging    -> /srv/grainport/grainport-api-staging     (branch: dev)
#   API  production -> /srv/grainport/grainport-api-production  (branch: main)
#   Web  staging    -> /srv/grainport/grainport-webapp-test
#   Web  production -> /srv/grainport/grainport-webapp
REMOTE_API_STAGING="$REMOTE_BASE/grainport-api-staging"
REMOTE_API_PRODUCTION="$REMOTE_BASE/grainport-api-production"
REMOTE_WEB_STAGING="$REMOTE_BASE/grainport-webapp-test"
REMOTE_WEB_PRODUCTION="$REMOTE_BASE/grainport-webapp"

# Branch checked out in each API directory
BRANCH_STAGING="dev"
BRANCH_PRODUCTION="main"

# Local repo paths — grainport-infra sits alongside the other repos in the parent directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
API_DIR="$ROOT_DIR/grainport-api"
APP_DIR="$ROOT_DIR/grainport-app"

# Caddy reverse proxy config
CADDY_LOCAL="$SCRIPT_DIR/Caddyfile"
CADDY_REMOTE="/etc/caddy/Caddyfile"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
TARGET="${1:-}"
ENV="${2:-}"

if [[ -z "$TARGET" || -z "$ENV" ]]; then
  echo "Usage: $0 <api|web|all> <staging|production>" >&2
  exit 1
fi

if [[ "$ENV" != "staging" && "$ENV" != "production" ]]; then
  echo "Error: environment must be 'staging' or 'production'" >&2
  exit 1
fi

COMPOSE_FILE="docker-compose.${ENV}.yml"
RELEASE_TAG="$(date +%Y-%m-%d-%H%M%S)"

if [[ "$ENV" == "production" ]]; then
  API_REMOTE_DIR="$REMOTE_API_PRODUCTION"
  API_BRANCH="$BRANCH_PRODUCTION"
  WEB_REMOTE_DIR="$REMOTE_WEB_PRODUCTION"
  WEB_URL="https://grainport.app"
  API_URL="https://api.grainport.app/status"
else
  API_REMOTE_DIR="$REMOTE_API_STAGING"
  API_BRANCH="$BRANCH_STAGING"
  WEB_REMOTE_DIR="$REMOTE_WEB_STAGING"
  WEB_URL="https://test.grainport.app"
  API_URL="https://api-staging.grainport.app/status"
fi

echo "==> Deploying target='${TARGET}' env='${ENV}' release='${RELEASE_TAG}'"

# ---------------------------------------------------------------------------
# Security gate — fail deploy on high/critical vulnerabilities
# ---------------------------------------------------------------------------
audit_deps() {
  local dir="$1"
  local level="${2:-critical}"
  if [ ! -f "$dir/package-lock.json" ]; then
    echo "==> [audit] SKIP $dir (no package-lock.json)"
    return 0
  fi
  echo "==> [audit] Checking dependencies in $dir (level=$level)"
  (cd "$dir" && npm audit --audit-level="$level" --production) || {
    echo "==> [audit] FAILED: $level-severity vulnerabilities in $dir" >&2
    exit 1
  }
}

# ---------------------------------------------------------------------------
# API deploy
# ---------------------------------------------------------------------------
deploy_api() {
  echo "==> [API] Deploying ${ENV} (branch=${API_BRANCH}) via Docker Compose"

  audit_deps "$API_DIR" "high"

  # Copy env file to server — it's gitignored, so git pull won't bring it
  echo "==> [API] Uploading .env.${ENV} to ${API_REMOTE_DIR}"
  scp -i "$SSH_KEY" "$API_DIR/.env.${ENV}" "${SSH_HOST}:${API_REMOTE_DIR}/.env.${ENV}"

  ssh -i "$SSH_KEY" "$SSH_HOST" <<EOF
set -e
cd "$API_REMOTE_DIR"
git checkout "$API_BRANCH"
git pull --ff-only
docker compose -f "$COMPOSE_FILE" down
docker compose -f "$COMPOSE_FILE" up -d --build
echo "==> [API] Container status:"
docker compose -f "$COMPOSE_FILE" ps
EOF

  echo "==> [API] Health check"
  curl -fsS "$API_URL" && echo || echo "WARN: health check failed for $API_URL"
}

# ---------------------------------------------------------------------------
# Web deploy
# ---------------------------------------------------------------------------
deploy_web() {
  echo "==> [Web] Building static export for ${ENV}"

  audit_deps "$APP_DIR" "critical"

  (
    cd "$APP_DIR"
    npm ci --no-audit

    # Expo reads EXPO_PUBLIC_* from .env.local/.env, not from shell environment.
    # Swap the correct environment file in for the build, then restore.
    HAS_LOCAL=false
    if [[ -f .env.local ]]; then
      HAS_LOCAL=true
      cp .env.local .env.local.bak
    fi
    cp ".env.${ENV}" .env.local

    NODE_ENV="${ENV}" npx expo export --platform web --clear

    # Restore original .env.local (or remove if none existed)
    if [[ "$HAS_LOCAL" == "true" ]]; then
      mv .env.local.bak .env.local
    else
      rm -f .env.local
    fi
  )

  DIST_DIR="$APP_DIR/dist"
  RELEASE_DIR="$WEB_REMOTE_DIR/releases/$RELEASE_TAG"
  CURRENT_LINK="$WEB_REMOTE_DIR/current"

  echo "==> [Web] Uploading to $SSH_HOST:$RELEASE_DIR"
  ssh -i "$SSH_KEY" "$SSH_HOST" "mkdir -p '$RELEASE_DIR'"
  rsync -av --delete \
    -e "ssh -i $SSH_KEY" \
    "$DIST_DIR/" \
    "$SSH_HOST:$RELEASE_DIR/"

  echo "==> [Web] Switching symlink"
  ssh -i "$SSH_KEY" "$SSH_HOST" \
    "ln -sfn '$RELEASE_DIR' '$CURRENT_LINK' && echo 'symlink ->' \$(readlink '$CURRENT_LINK')"

  echo "==> [Web] Smoke tests"
  for path in "" "/login" "/transport" "/settings"; do
    code=$(curl -s -o /dev/null -w "%{http_code}" "$WEB_URL$path")
    echo "  $WEB_URL$path -> $code"
  done
}

# ---------------------------------------------------------------------------
# Caddy deploy
# ---------------------------------------------------------------------------
deploy_caddy() {
  echo "==> [Caddy] Deploying reverse proxy config"

  # Upload to a temp file, validate, then commit and reload.
  # If validation fails, the live config is left untouched.
  scp -i "$SSH_KEY" "$CADDY_LOCAL" "${SSH_HOST}:${CADDY_REMOTE}.new"

  ssh -i "$SSH_KEY" "$SSH_HOST" <<EOF
set -e
caddy validate --config "${CADDY_REMOTE}.new"
mv "${CADDY_REMOTE}.new" "${CADDY_REMOTE}"
systemctl reload caddy
echo "==> [Caddy] Config reloaded"
EOF
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "$TARGET" in
  api) deploy_api ;;
  web) deploy_web ;;
  caddy) deploy_caddy ;;
  all)
    deploy_api
    deploy_web
    deploy_caddy
    ;;
  *)
    echo "Error: target must be 'api', 'web', 'caddy', or 'all'" >&2
    exit 1
    ;;
esac

echo "==> Done."

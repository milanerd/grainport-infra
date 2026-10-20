#!/bin/bash
set -euo pipefail

# =============================================================================
# GrainPort — Full server backup
#
# Backs up everything needed to recreate the server stack from scratch:
#   1. Supabase PostgreSQL databases (production + staging via pg_dump)
#   2. API .env files (production + staging) — gitignored, only on server
#   3. Caddy reverse proxy config
#   4. Docker compose files (snapshot of current deployment config)
#   5. Crontab for this user
#
# Cron:  0 3 * * * /opt/backups/grainport-backup.sh >> /var/log/grainport-backup.log 2>&1
#
# Requires env vars (auto-loaded from the API .env files below if not set):
#   PROD_DB_PASSWORD      — Supabase production database password
#   STAGING_DB_PASSWORD   — Supabase staging database password (optional)
#   (these map to SUPABASE_DB_PASSWORD in the API .env files)
#
# NOTE: the Supabase service_role key (JWT) is NOT a valid Postgres password.
# pg_dump needs the project's database password
# (Supabase Dashboard → Database → Database password).
#
# Off-server sync (optional): set any of these to push after backup:
#   BACKUP_RCLONE_REMOTE   — e.g. "gdrive:grainport-backups"
#   BACKUP_SCP_TARGET      — e.g. "user@backup-host:/backups/grainport"
# =============================================================================

BACKUP_DIR="${BACKUP_DIR:-/opt/backups/grainport}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
DATE=$(date +%Y%m%d_%H%M%S)
LOG_TAG="[grainport-backup]"

# Server paths
API_STAGING_DIR="/srv/grainport/grainport-api-staging"
API_PRODUCTION_DIR="/srv/grainport/grainport-api-production"

# Auto-load database passwords from the API env files (gitignored, only on server).
if [ -z "${PROD_DB_PASSWORD:-}" ] && [ -f "$API_PRODUCTION_DIR/.env.production" ]; then
  PROD_DB_PASSWORD="$(grep -E '^SUPABASE_DB_PASSWORD=' "$API_PRODUCTION_DIR/.env.production" | head -n1 | cut -d= -f2-)"
fi
if [ -z "${STAGING_DB_PASSWORD:-}" ] && [ -f "$API_STAGING_DIR/.env.staging" ]; then
  STAGING_DB_PASSWORD="$(grep -E '^SUPABASE_DB_PASSWORD=' "$API_STAGING_DIR/.env.staging" | head -n1 | cut -d= -f2-)"
fi

log() { echo "$LOG_TAG $(date '+%Y-%m-%d %H:%M:%S') $*"; }
warn() { echo "$LOG_TAG $(date '+%Y-%m-%d %H:%M:%S') WARN $*" >&2; }

log "Starting backup (date=$DATE)"


# ---------------------------------------------------------------------------
# 1. PostgreSQL databases (Supabase, via pg_dump)
# ---------------------------------------------------------------------------
if [ -n "${PROD_DB_PASSWORD:-}" ]; then
  PROD_REF="ufbayqdrluagcfabflih"
  PROD_DB="postgresql://postgres:${PROD_DB_PASSWORD}@db.${PROD_REF}.supabase.co:5432/postgres?sslmode=require"
  PROD_FILE="$BACKUP_DIR/prod_${DATE}.sql"

  log "Starting production database backup..."
  pg_dump "$PROD_DB" --no-owner --clean --file="$PROD_FILE"
  log "Production DB backup: $(du -h "$PROD_FILE" | cut -f1)"
else
  warn "PROD_DB_PASSWORD not set — skipping production database backup"
fi

if [ -n "${STAGING_DB_PASSWORD:-}" ]; then
  STAGING_REF="zsjllpxjelcbyfvcduof"
  STAGING_DB="postgresql://postgres:${STAGING_DB_PASSWORD}@db.${STAGING_REF}.supabase.co:5432/postgres?sslmode=require"
  STAGING_FILE="$BACKUP_DIR/staging_${DATE}.sql"

  log "Starting staging database backup..."
  pg_dump "$STAGING_DB" --no-owner --clean --file="$STAGING_FILE"
  log "Staging DB backup: $(du -h "$STAGING_FILE" | cut -f1)"
else
  warn "STAGING_DB_PASSWORD not set — skipping staging database backup"
fi


# ---------------------------------------------------------------------------
# 2. Server configuration — tar archive for full stack recreation
# ---------------------------------------------------------------------------
CONFIG_TMP="$BACKUP_DIR/config_${DATE}"
CONFIG_TAR="$BACKUP_DIR/config_${DATE}.tar.gz"
mkdir -p "$CONFIG_TMP"

# 2a. API env files (gitignored — only copy lives on this server)
if [ -f "$API_PRODUCTION_DIR/.env.production" ]; then
  cp "$API_PRODUCTION_DIR/.env.production" "$CONFIG_TMP/api.env.production"
  log "Backed up API .env.production"
else
  warn "Missing $API_PRODUCTION_DIR/.env.production"
fi

if [ -f "$API_STAGING_DIR/.env.staging" ]; then
  cp "$API_STAGING_DIR/.env.staging" "$CONFIG_TMP/api.env.staging"
  log "Backed up API .env.staging"
else
  warn "Missing $API_STAGING_DIR/.env.staging"
fi

# 2b. Caddy reverse proxy config
if [ -f /etc/caddy/Caddyfile ]; then
  cp /etc/caddy/Caddyfile "$CONFIG_TMP/Caddyfile"
  log "Backed up Caddyfile"
else
  warn "Missing /etc/caddy/Caddyfile"
fi

# 2c. Docker compose files (snapshot of current deployment state)
if [ -f "$API_PRODUCTION_DIR/docker-compose.production.yml" ]; then
  cp "$API_PRODUCTION_DIR/docker-compose.production.yml" "$CONFIG_TMP/"
  log "Backed up docker-compose.production.yml"
fi
if [ -f "$API_STAGING_DIR/docker-compose.staging.yml" ]; then
  cp "$API_STAGING_DIR/docker-compose.staging.yml" "$CONFIG_TMP/"
  log "Backed up docker-compose.staging.yml"
fi
if [ -f "$API_PRODUCTION_DIR/Dockerfile" ]; then
  cp "$API_PRODUCTION_DIR/Dockerfile" "$CONFIG_TMP/Dockerfile"
fi

# 2d. Crontab
crontab -l 2>/dev/null > "$CONFIG_TMP/crontab.txt" && log "Backed up crontab" || warn "No crontab for current user"

# 2e. Git revision info (so you know which commit was deployed)
git -C "$API_PRODUCTION_DIR" rev-parse HEAD > "$CONFIG_TMP/git_production_rev.txt" 2>/dev/null || true
git -C "$API_STAGING_DIR" rev-parse HEAD > "$CONFIG_TMP/git_staging_rev.txt" 2>/dev/null || true

# 2f. Create the config tarball
tar -czf "$CONFIG_TAR" -C "$BACKUP_DIR" "config_${DATE}"
rm -rf "$CONFIG_TMP"
log "Config archive: $(du -h "$CONFIG_TAR" | cut -f1)"


# ---------------------------------------------------------------------------
# 3. Rotation — clean up old backups (both .sql and .tar.gz)
# ---------------------------------------------------------------------------
DELETED_DB=$(find "$BACKUP_DIR" -name "*.sql" -mtime +${RETENTION_DAYS} -delete -print | wc -l | tr -d ' ')
DELETED_CFG=$(find "$BACKUP_DIR" -name "config_*.tar.gz" -mtime +${RETENTION_DAYS} -delete -print | wc -l | tr -d ' ')
TOTAL_DELETED=$((DELETED_DB + DELETED_CFG))
if [ "$TOTAL_DELETED" -gt 0 ]; then
  log "Rotated $TOTAL_DELETED old file(s) (${DELETED_DB} DB + ${DELETED_CFG} config, retention: ${RETENTION_DAYS} days)"
fi


# ---------------------------------------------------------------------------
# 4. Off-server sync (optional — configure BACKUP_RCLONE_REMOTE or BACKUP_SCP_TARGET)
# ---------------------------------------------------------------------------
BACKUP_TODAY_FILES=$(find "$BACKUP_DIR" -name "*${DATE}*" -type f | tr '\n' ' ')

if [ -n "${BACKUP_RCLONE_REMOTE:-}" ]; then
  log "Syncing to rclone remote: $BACKUP_RCLONE_REMOTE"
  for f in $BACKUP_TODAY_FILES; do
    rclone copy "$f" "$BACKUP_RCLONE_REMOTE"
  done
  log "rclone sync complete"
fi

if [ -n "${BACKUP_SCP_TARGET:-}" ]; then
  log "Syncing via scp to: $BACKUP_SCP_TARGET"
  scp $BACKUP_TODAY_FILES "$BACKUP_SCP_TARGET"
  log "scp sync complete"
fi


# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
TOTAL_FILES=$(ls "$BACKUP_DIR" | wc -l | tr -d ' ')
log "Done. $TOTAL_FILES files in $BACKUP_DIR"
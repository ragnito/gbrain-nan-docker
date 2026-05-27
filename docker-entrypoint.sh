#!/bin/bash
set -e

# ─── Validate required env vars ───────────────────────────────────────
for var in NAN_API_KEY LITELLM_MASTER_KEY; do
  if [ -z "${!var}" ]; then
    echo "ERROR: $var is not set" >&2
    exit 1
  fi
done

POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
POSTGRES_DB="${POSTGRES_DB:-gbrain}"

# ─── PostgreSQL setup ─────────────────────────────────────────────────
PGDATA="/data/pg"
PGCONF="/etc/postgresql/17/main"

if [ ! -f "$PGDATA/PG_VERSION" ]; then
  echo "[entrypoint] Initializing PostgreSQL cluster at $PGDATA ..."
  mkdir -p "$PGDATA"
  chown postgres:postgres "$PGDATA"
  chmod 700 "$PGDATA"
  # Symlink so pg_ctlcluster finds the right config
  rm -rf "$PGCONF"
  mkdir -p "$(dirname $PGCONF)"
  ln -s "$PGDATA" "$PGCONF"
  su - postgres -c "/usr/lib/postgresql/17/bin/initdb -D $PGDATA --encoding=UTF8 --locale=C"
  # Configure for password auth on localhost TCP
  cat >> "$PGDATA/pg_hba.conf" <<'EOF'
host all all 127.0.0.1/32 md5
host all all ::1/128 md5
EOF
  echo "listen_addresses = '127.0.0.1'" >> "$PGDATA/postgresql.conf"
else
  echo "[entrypoint] Found existing PostgreSQL cluster at $PGDATA"
fi

# ─── Apply low-memory profile for Docker compatibility ──────────────────
# Default shared_buffers=128MB + posix dynamic shared memory can exceed
# Docker's default /dev/shm (64MB), causing PostgreSQL to fail silently.
echo "[entrypoint] Applying low-memory PostgreSQL profile ..."
cat >> "$PGDATA/postgresql.conf" <<'PGCONF'
shared_buffers = 16MB
dynamic_shared_memory_type = sysv
max_connections = 25
work_mem = 1MB
PGCONF

echo "[entrypoint] Starting PostgreSQL on :5432 ..."
su - postgres -c "/usr/lib/postgresql/17/bin/pg_ctl -D $PGDATA -l /tmp/pg.log start"

# Wait for PostgreSQL to accept connections
for i in $(seq 1 15); do
  if su - postgres -c "psql -c 'SELECT 1' template1" >/dev/null 2>&1; then
    echo "[entrypoint] PostgreSQL is ready"
    break
  fi
  if [ "$i" -eq 15 ]; then
    echo "[entrypoint] ERROR: PostgreSQL did not start" >&2
    exit 1
  fi
  sleep 1
done

# Create user and database if not exist
su - postgres -c "psql -tc \"SELECT 1 FROM pg_roles WHERE rolname='${POSTGRES_USER}'\"" | grep -q 1 || \
  su - postgres -c "psql -c \"CREATE ROLE ${POSTGRES_USER} LOGIN SUPERUSER BYPASSRLS PASSWORD '${POSTGRES_PASSWORD}'\""
su - postgres -c "psql -tc \"SELECT 1 FROM pg_database WHERE datname='${POSTGRES_DB}'\"" | grep -q 1 || \
  su - postgres -c "createdb -O ${POSTGRES_USER} ${POSTGRES_DB}"
su - postgres -c "psql ${POSTGRES_DB} -tc \"SELECT 1 FROM pg_extension WHERE extname='vector'\"" | grep -q 1 || \
  su - postgres -c "psql ${POSTGRES_DB} -c 'CREATE EXTENSION IF NOT EXISTS vector'"

export DATABASE_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@127.0.0.1:5432/${POSTGRES_DB}"

# ─── Setup directories ────────────────────────────────────────────────
GBRAIN_HOME="/data/gbrain-home"
mkdir -p "$GBRAIN_HOME"

# ─── Write gbrain config.json ─────────────────────────────────────────
cat > "$GBRAIN_HOME/config.json" <<EOF
{
  "engine": "postgres",
  "database_url": "${DATABASE_URL}",
  "embedding_model": "litellm:qwen3-embedding",
  "embedding_dimensions": 1536,
  "chat_model": "litellm:qwen3.6",
  "expansion_model": "litellm:qwen3.6",
  "provider_base_urls": {
    "litellm": "http://localhost:4000"
  }
}
EOF

echo "[entrypoint] gbrain config written to $GBRAIN_HOME/config.json"

# ─── Export env vars for gbrain ────────────────────────────────────────
export LITELLM_BASE_URL=http://localhost:4000
export LITELLM_API_KEY="$LITELLM_MASTER_KEY"
export ANTHROPIC_BASE_URL=http://localhost:4001
export ANTHROPIC_API_KEY="$LITELLM_MASTER_KEY"

# ─── Start LiteLLM proxy ──────────────────────────────────────────────
# Unset DATABASE_URL so LiteLLM doesn't try to connect Prisma.
# Save it first so we can restore it for gbrain later.
SAVED_DATABASE_URL="$DATABASE_URL"
unset DATABASE_URL
echo "[entrypoint] Starting LiteLLM on :4000 ..."
litellm --config /etc/gbrain/litellm/config.yaml --port 4000 --telemetry False &
LITELLM_PID=$!

# Wait for LiteLLM to be healthy
echo "[entrypoint] Waiting for LiteLLM to be ready ..."
for i in $(seq 1 30); do
  if curl -sf http://localhost:4000/health/liveness >/dev/null 2>&1; then
    echo "[entrypoint] LiteLLM is ready"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "[entrypoint] ERROR: LiteLLM did not become ready in 30s" >&2
    exit 1
  fi
  sleep 1
done

# ─── Start anthropic-shim ─────────────────────────────────────────────
echo "[entrypoint] Starting anthropic-shim on :4001 ..."
bun run /etc/gbrain/litellm/anthropic-shim.ts &
SHIM_PID=$!

# Wait for shim to be ready
echo "[entrypoint] Waiting for anthropic-shim to be ready ..."
for i in $(seq 1 30); do
  if curl -sf -o /dev/null -w "%{http_code}" http://localhost:4001/ 2>/dev/null | grep -qE '^[23]'; then
    echo "[entrypoint] anthropic-shim is ready"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "[entrypoint] ERROR: anthropic-shim did not become ready in 30s" >&2
    exit 1
  fi
  sleep 1
done

# ─── Restore DATABASE_URL for gbrain ──────────────────────────────────
# LiteLLM doesn't need it (we unset it above), but gbrain does.
export DATABASE_URL="$SAVED_DATABASE_URL"

# ─── Run migrations ───────────────────────────────────────────────────
echo "[entrypoint] Running gbrain migrations ..."
gbrain apply-migrations --yes --non-interactive 2>/dev/null || true

# ─── Apply tier routing (DB-backed) ───────────────────────────────────
echo "[entrypoint] Applying tier routing ..."
gbrain config set models.default claude-sonnet-4-6 2>/dev/null || true
gbrain config set models.tier.utility claude-haiku-4-5-20251001 2>/dev/null || true
gbrain config set models.tier.reasoning claude-sonnet-4-6 2>/dev/null || true
gbrain config set models.tier.deep claude-sonnet-4-6 2>/dev/null || true

# ─── Start nginx reverse proxy ────────────────────────────────────────
echo "[entrypoint] Starting nginx on :80 ..."
nginx -g 'daemon off;' &

# ─── Build command with optional flags ─────────────────────────────────
GBRAIN_CMD=("$@")
if [ -n "$PUBLIC_URL" ]; then
  GBRAIN_CMD+=("--public-url" "$PUBLIC_URL")
fi

# ─── Execute the command ──────────────────────────────────────────────
echo "[entrypoint] Starting: ${GBRAIN_CMD[*]}"
exec "${GBRAIN_CMD[@]}"

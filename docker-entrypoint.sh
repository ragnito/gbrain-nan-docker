#!/bin/bash
set -e

# ─── Validate required env vars ───────────────────────────────────────
for var in DATABASE_URL NAN_API_KEY LITELLM_MASTER_KEY; do
  if [ -z "${!var}" ]; then
    echo "ERROR: $var is not set" >&2
    exit 1
  fi
done

# ─── Setup directories ────────────────────────────────────────────────
GBRAIN_HOME="${GBRAIN_HOME:-/root/.gbrain}"
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
# We restore it later for gbrain commands.
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
export DATABASE_URL

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

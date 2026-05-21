FROM oven/bun:1

# Install Python 3 + pip for LiteLLM
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-venv \
    curl \
    nginx \
    && rm -rf /var/lib/apt/lists/*

# Install LiteLLM proxy globally
RUN pip3 install --break-system-packages 'litellm[proxy]'

# Install gbrain globally from GitHub
RUN bun install -g github:garrytan/gbrain

# Copy LiteLLM config and anthropic shim
COPY litellm/config.yaml /etc/gbrain/litellm/config.yaml
COPY litellm/anthropic-shim.ts /etc/gbrain/litellm/anthropic-shim.ts

# Copy nginx config
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Copy entrypoint
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Expose ports
# 80 - nginx (reverse proxy)
# 4000 - LiteLLM proxy
# 4001 - Anthropic shim
# 3131 - gbrain serve --http (direct, not exposed to host)
EXPOSE 80 4000 4001 3131

# Default command: gbrain serve --http
CMD ["gbrain", "serve", "--http"]

ENTRYPOINT ["docker-entrypoint.sh"]

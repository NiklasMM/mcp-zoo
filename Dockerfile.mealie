FROM node:22-slim

# git is needed for `uvx git+https://...` sources
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# uv / uvx. Pin a specific version tag instead of :latest once you've chosen one.
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

# Pin with: docker compose build --build-arg SUPERGATEWAY_VERSION=x.y.z
ARG SUPERGATEWAY_VERSION=latest
RUN npm install -g supergateway@${SUPERGATEWAY_VERSION}

# Cache for uv downloads (packages + managed Python), kept in a named volume
ENV UV_CACHE_DIR=/cache/uv \
    UV_PYTHON_INSTALL_DIR=/cache/python
RUN mkdir -p /cache && chown node:node /cache

USER node
EXPOSE 8000
ENTRYPOINT ["supergateway"]

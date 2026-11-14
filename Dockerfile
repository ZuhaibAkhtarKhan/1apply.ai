# syntax=docker/dockerfile:1.7
#
# 1-Apply web app (apps/web) — multi-stage build producing a Next.js standalone server.
# Build from the repo root:  docker build -t 1apply-web .
#
# NEXT_PUBLIC_* values are inlined into the browser bundle at build time, so they are
# build args. Server secrets are runtime env only (see docker-compose.yml) — never bake them in.

ARG NODE_VERSION=22

# ---------------------------------------------------------------------------
# deps: install workspace dependencies from the lockfile (cached unless manifests change)
# ---------------------------------------------------------------------------
FROM node:${NODE_VERSION}-bookworm-slim AS deps
WORKDIR /repo

COPY package.json package-lock.json .npmrc ./
COPY apps/web/package.json apps/web/
COPY apps/extension/package.json apps/extension/
COPY packages/config/package.json packages/config/
COPY packages/contracts/package.json packages/contracts/
COPY packages/domain/package.json packages/domain/
COPY packages/form-engine/package.json packages/form-engine/
COPY workers/ai-jobs/package.json workers/ai-jobs/

RUN --mount=type=cache,target=/root/.npm \
    npm ci --no-audit --no-fund

# ---------------------------------------------------------------------------
# builder: compile the Next.js app in standalone mode
# ---------------------------------------------------------------------------
FROM node:${NODE_VERSION}-bookworm-slim AS builder
WORKDIR /repo

COPY --from=deps /repo/node_modules ./node_modules
COPY . .

ARG NEXT_PUBLIC_APP_URL=http://localhost:3000
ARG NEXT_PUBLIC_SUPABASE_URL
ARG NEXT_PUBLIC_SUPABASE_ANON_KEY
ARG NEXT_PUBLIC_EXTENSION_ORIGIN=

ENV NEXT_PUBLIC_APP_URL=${NEXT_PUBLIC_APP_URL} \
    NEXT_PUBLIC_SUPABASE_URL=${NEXT_PUBLIC_SUPABASE_URL} \
    NEXT_PUBLIC_SUPABASE_ANON_KEY=${NEXT_PUBLIC_SUPABASE_ANON_KEY} \
    NEXT_PUBLIC_EXTENSION_ORIGIN=${NEXT_PUBLIC_EXTENSION_ORIGIN} \
    NEXT_OUTPUT=standalone \
    NEXT_TELEMETRY_DISABLED=1 \
    LOW_MEM_BUILD=1 \
    NODE_OPTIONS=--max-old-space-size=4096

RUN npm run build -w @1apply/web

# ---------------------------------------------------------------------------
# runner: minimal runtime image
# ---------------------------------------------------------------------------
FROM node:${NODE_VERSION}-bookworm-slim AS runner
WORKDIR /app

ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    HOSTNAME=0.0.0.0 \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright

# Standalone server + workspace packages it traced, then static assets and public files.
COPY --from=builder --chown=node:node /repo/apps/web/.next/standalone ./
COPY --from=builder --chown=node:node /repo/apps/web/.next/static ./apps/web/.next/static
COPY --from=builder --chown=node:node /repo/apps/web/public ./apps/web/public

# Optional: Chromium for the server-side Playwright host-submit fallback
# (only used when ENABLE_SERVER_HOST_SUBMIT=true). Adds roughly 500 MB, so it is off by default.
ARG INSTALL_PLAYWRIGHT_CHROMIUM=false
COPY --from=deps /repo/node_modules/playwright /tmp/pw/node_modules/playwright
COPY --from=deps /repo/node_modules/playwright-core /tmp/pw/node_modules/playwright-core
RUN if [ "$INSTALL_PLAYWRIGHT_CHROMIUM" = "true" ]; then \
      node /tmp/pw/node_modules/playwright/cli.js install --with-deps chromium \
      && chown -R node:node /ms-playwright \
      && rm -rf /var/lib/apt/lists/*; \
    fi \
    && rm -rf /tmp/pw

USER node
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:3000/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "apps/web/server.js"]

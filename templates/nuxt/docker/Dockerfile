# ── Development target ───────────────────────────────────────────────
FROM node:22-alpine AS development

# Build tools for native addons (sharp, bcrypt)
RUN apk add --no-cache python3 make g++

WORKDIR /app

CMD ["sh", "-c", "npm install && npm run dev -- --host 0.0.0.0"]

# ── Build stage (intermediate) ──────────────────────────────────────
FROM node:22-alpine AS build

# Build tools for native addons
RUN apk add --no-cache python3 make g++

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY . .
RUN npm run build

# ── DRIZZLE ONLY (1 of 2) ────────────────────────────────────────────
# Delete this block for an app without Drizzle, together with the matching
# block in the production stage. Check first: grep -n drizzle package.json
# Migration dependencies (pure JS, no native compilation needed)
RUN mkdir /migrate \
    && cd /migrate \
    && npm install drizzle-kit drizzle-orm mysql2

# ── Production target ────────────────────────────────────────────────
FROM node:22-alpine AS production

RUN apk add --no-cache dumb-init

WORKDIR /app

# Nitro server output
COPY --from=build /app/.output ./.output

# ── DRIZZLE ONLY (2 of 2) ────────────────────────────────────────────
# Delete all three COPYs for an app without Drizzle. `COPY --from` of a path
# that doesn't exist is a hard build failure, not a no-op — a Nuxt app with no
# server/database/migrations and no drizzle.config.ts cannot build past here:
#   ERROR: "/app/server/database/migrations": not found
# Nitro's .output is self-contained, so a non-Drizzle app needs no node_modules
# in production at all. See apps/phnx-solution (phnx-solution-coming-soon) for
# the worked example with this block removed.
# Migration files and dependencies
COPY --from=build /app/server/database/migrations ./server/database/migrations
COPY --from=build /app/drizzle.config.ts ./
COPY --from=build /migrate/node_modules ./node_modules

# Storage directory for uploads
RUN mkdir -p /app/storage \
    && chown -R node:node /app/storage

COPY docker/entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh

USER node

EXPOSE 3000

ENTRYPOINT ["entrypoint.sh"]
CMD ["dumb-init", "node", ".output/server/index.mjs"]

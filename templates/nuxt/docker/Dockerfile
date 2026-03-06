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

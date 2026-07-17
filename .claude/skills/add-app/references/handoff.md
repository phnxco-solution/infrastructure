# Phase 6 — Handoff

The user should not have to search for anything. Give ordered steps, real values
substituted, and offer to run what can be run.

## Contents

- [Order matters](#order-matters)
- [1. Push the infrastructure first](#1-push-the-infrastructure-first)
- [2. VPS prep](#2-vps-prep)
- [3. Secrets](#3-secrets)
- [4. Push the app](#4-push-the-app)
- [5. DNS last](#5-dns-last)
- [Post-deploy check](#post-deploy-check)
- [Deploy failure decoder](#deploy-failure-decoder)
- [The per-app README](#the-per-app-readme)

## Order matters

Pushing the app repo triggers a build **and a deploy**. Everything the deploy touches has
to exist first:

```
infra push → VPS pull → storage skeleton → DB → .env → secrets → app push → DNS
```

Get this backwards and the deploy fails on a missing `apps/<name>` directory.

## 1. Push the infrastructure first

```bash
cd <infra repo> && git push
```

Claude cannot do this — the user's SSH key isn't in the session's agent. Say so rather
than trying and reporting a confusing failure.

## 2. VPS prep

```bash
cd /opt/infrastructure && git pull

# Storage skeleton — NOT optional.
# The volume shadows the image's storage/, so an empty host dir means `php artisan
# optimize` cannot write its view cache and the container dies on boot.
sudo mkdir -p /opt/volumes/apps/<name>/storage/{app/public,framework/{cache/data,sessions,views},logs}
sudo chown -R 82:82 /opt/volumes/apps/<name>/storage
```

`82` is `www-data` in `php:8.4-fpm-alpine` (Debian-based PHP images use `33` — verify with
`docker run --rm <base-image> id www-data`). `setup.sh` only creates `/opt/volumes/apps`,
never the per-app tree.

**Node apps: different UID, and `sudo` is the trap.** The nuxt template ends `USER node`
= uid **1000**, and `setup.sh` already leaves `/opt/volumes/apps` owned by `deploy`, also
uid 1000. So create the tree **as deploy, without sudo**:

```bash
mkdir -p /opt/volumes/apps/<name>/{storage,logs}    # no sudo → deploy:deploy (1000) = node
```

`sudo` here is destructive by omission: root-owned dirs, the container can't write, and
**nothing tells you** — the `/` healthcheck still passes, Traefik still routes, the site
looks fine. Daily logging silently writes nothing, and anything persisted to
`/app/storage` is dropped (`phnx-solution` writes every newsletter signup to
`/app/storage/subscribers.ndjson`). Prove it instead:

```bash
docker compose exec -T web touch /app/storage/.probe && echo writable
```

**Never `chown /opt/volumes`** wholesale — container UIDs own their data dirs.

Database — nothing auto-creates it; MySQL only receives a root password:

```sql
CREATE DATABASE <db> CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '<user>'@'%' IDENTIFIED BY '<password>';
GRANT ALL PRIVILEGES ON <db>.* TO '<user>'@'%';
FLUSH PRIVILEGES;
```

Then write `.env` — see `references/env-contract.md` for the file and the traps.

## 3. Secrets

All five, on the app repo. Check first — they may already exist:

```bash
gh secret list --repo <org>/<app>
```

`VPS_HOST`, `VPS_USER`, `VPS_PORT` and `VPS_SSH_KEY` are **identical across every app
here**, so take them from a repo that already deploys. Secrets can't be read back, so
ask the user for the values or the key path once, then:

```bash
gh secret set VPS_SSH_KEY --repo <org>/<app> < ~/.ssh/<key>   # pipe, never paste
gh secret set VPS_HOST    --repo <org>/<app> --body "<ip>"
gh secret set VPS_USER    --repo <org>/<app> --body "deploy"
gh secret set VPS_PORT    --repo <org>/<app> --body "41922"
```

Pipe `VPS_SSH_KEY` from the file. A pasted key loses its trailing newline and produces a
bare `ssh: handshake failed` with no hint — the most common first-deploy failure. To check
the newline without printing key material:

```bash
[ -n "$(tail -c1 ~/.ssh/<key>)" ] && echo "MISSING trailing newline" || echo "newline ok"
```

**`GHCR_PAT` is the user's to run, not Claude's.** It reads stdin, and with no TTY the
call stores an **empty secret and reports success** — the deploy then fails `unauthorized`
and the decoder below sends you hunting a `read:packages` scope that was never the
problem. Hand it over:

```
! gh secret set GHCR_PAT --repo <org>/<app>
```

**Never ask for a PAT or a private key in chat.** It stays in the transcript. Same reason
not to `cat`, `echo` or hexdump a key "to check it".

`VPS_USER` must be `deploy` (sshd has `AllowUsers deploy`). The key's public half must be
in `/home/deploy/.ssh/authorized_keys`. A passphrase-protected key also needs a
`passphrase:` input on the ssh-action, which the template doesn't pass.

## 4. Push the app

```bash
cd <app repo> && git push
```

Triggers build + deploy. Watch it: `gh run watch` or `gh run list --workflow=deploy.yml`.

## 5. DNS last

Cloudflare **proxied** A record → VPS IP. Per the project's own gotcha, don't point a
host until its containers are up, or Traefik answers 404.

Cert work depends on the host's **label depth**, not just its zone. A wildcard covers one
label: `app.phnx-solution.com` needs nothing, `api.app.phnx-solution.com` is outside both
Universal SSL and the origin cert and serves a **526**. Flatten it to
`app-api.phnx-solution.com` — that's what commit `2a06db0` did, and it's cheaper than a
cert. Agree the hostname in Phase 1, before anything is built.

A separate zone usually needs its own origin cert on the VPS plus an entry in
`traefik/dynamic/tls.yml` — but not always: `unimaginable.rs` runs without one, which
works only where the zone's Cloudflare SSL mode is Full rather than Full (strict). Check
the mode.

## Post-deploy check

```bash
cd /opt/infrastructure/apps/<name>
docker compose ps                              # all healthy, nothing restarting
docker compose exec -T app php artisan about   # env, DB, cache, queue, session
curl -sI https://<domain> | head -1
```

`php artisan about` is the one that matters — it catches the whole silent-default class
in a single call. A restarting `worker` almost always means the cache driver is wrong.

## Deploy failure decoder

| Symptom | Cause |
|---|---|
| `ssh: handshake failed ... [none publickey]` | Key or user. Handshake happening at all proves HOST and PORT are right — sshd answered and rejected the key. Usually the trailing newline. |
| `cd: /opt/infrastructure/apps/<name>: No such file` | Infra not pushed or not pulled. |
| `unauthorized` on pull | GHCR login on the VPS, or a `GHCR_PAT` without `read:packages`. |
| Site 404s through Traefik | Container not up, or DNS pointed before the app existed. |
| `WARN The SQLite database ... does not exist` | `DB_CONNECTION` isn't `mysql`. See `references/env-contract.md`. |
| Worker restart-looping | Cache driver hitting a DB that isn't there. Same cause. |
| Assets 404 / site unstyled, asset URLs point at `localhost:5173` | `public/hot` baked into the image — `Vite::isRunningHot()` is literally `is_file(public_path('/hot'))`. On an Inertia app it also makes the SSR gateway treat the build as hot, skipping the bundle check and posting to whatever that file contains. |
| `gh api /orgs/.../packages` 404 | The `gh` token lacks `read:packages`. Not evidence the images are missing. |

## The per-app README

`apps/<name>/README.md`, next to the compose — where someone looks when it breaks:

```markdown
# <name>

<domain> — <stack>. Repo: <org>/<app>

## Services
| Service | Why it exists |
|---|---|
| app | php-fpm |
| nginx | Traefik-facing, static assets baked in |
| worker | <the evidence: N Mailables implement ShouldQueue> |
| ssr | <why, and that it fails soft to CSR> |

No scheduler: <the evidence — no Schedule:: anywhere>.

## Required .env
<the app-specific keys and why — especially anything that fails silently>

## First boot
<storage skeleton, DB, DNS>

## Quirks
<what this app does that the template doesn't expect, and why>
```

Record the *evidence* for each decision, not just the decision. "No scheduler" is a
claim; "no `Schedule::` anywhere, `app/Console/Commands` empty" is a fact someone can
re-check in a year.

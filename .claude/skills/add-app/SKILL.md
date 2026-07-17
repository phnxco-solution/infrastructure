---
name: add-app
description: Onboard a new website/app onto the shared Hostinger VPS — detect what the app actually needs, scaffold its Docker files, production compose and deploy workflow, verify the running stack locally, commit both repos, then hand back the exact manual steps and gh CLI commands. Use when adding a new app/website/service to the infrastructure, deploying an existing repo to the VPS for the first time, wiring an app into Traefik/MySQL/Redis, or when the user says "add a new app", "onboard this repo", "deploy this to the VPS", or invokes /add-app.
---

# Add an app to the shared VPS

Onboarding is not scaffolding. Copying template files is the easy part; the work is
**finding out what this particular app needs** and **proving the stack runs before it
reaches the VPS**. The files in `templates/` are sources, not a plan.

## Two repos

Work spans two repos and it is easy to run a command in the wrong one:

- **the infra repo** — holds this skill, `apps/`, `templates/`, `CLAUDE.md`. Normally the
  session's cwd, since that's where the skill is invoked.
- **the app repo** — somewhere else entirely, e.g. `~/Projects/www/clients/<app>` or
  `~/Projects/www/personal/<app>`.

Phase 0's checks run **in the app repo**. Phase 3 writes to the **infra repo**. Phase 4
builds from the app repo but mounts files out of the infra repo. Use absolute paths
rather than leaning on cwd, and `cd` explicitly in each Bash call — working directory
persists between calls and drifts.

Never assume the app repo's directory name is the app name: `~/…/personal/phnx-solution`
is an unrelated workspace, while the deployed `phnx-solution` app builds from
`phnx-solution-coming-soon`. Match the repo to `image:` in `apps/<name>/docker-compose.yml`.

## Arguments

Anything given is a head start, not a spec — verify each against the repo, and ask for
what's missing. Accepted in any order:

- **a path** → the app repo (`~/Projects/www/clients/foo`)
- **a hostname** → the production domain (`foo.phnx-solution.com`)
- **a bare name** → the app name; find the repo before assuming a path

With no arguments, ask for the repo path first — everything in Phase 0 needs it.
Derive the app name from the repo directory and confirm it: it becomes the compose
project name, the image name, the Traefik router and the volume path, and it is
painful to change later.

## Three rules

1. **Detect, don't assume.** Every claim about the app (needs a worker, needs intl,
   builds with Node alone) must come from a command whose output was actually seen. The
   template is a hypothesis, not evidence.
2. **Verify by running it.** A green build proves almost nothing — see
   `references/verify.md`. Do not commit before the stack serves a real page locally.
3. **Never commit a secret.** `.env` lives on the VPS only. A value needed at image
   build time is a build arg, not a baked file.

## Claim the name, and check it isn't already done

Both checks are cheap, and skipping either can **remove a running production app**. Every
`deploy.yml` here runs `docker compose up -d --remove-orphans`, and Compose scopes
orphans by the `name:` label, **not the directory** — so a second project sharing a name
stops and removes the first one's containers, from a deploy that reports green.

**Is this already onboarded?**

```bash
ls apps/<name>/ 2>/dev/null
ls <app-repo>/docker/ <app-repo>/.github/workflows/deploy.yml 2>/dev/null
```

Anything present → this is an **edit, not a scaffold**. Diff the live file against what
you'd generate, change only what was asked, skip the CLAUDE.md row. **Never regenerate
`apps/<name>/docker-compose.yml` from the template**: the live one carries hand-tuned
services the template has never heard of (`unimaginable`'s `content-worker` with
`--timeout=1500` and `stop_grace_period: 1530s`). Dropping a service from that file isn't
a diff the user can review away — the next deploy's `--remove-orphans` kills the running
container, mid-job.

**Is the name free?** It's four namespaces at once, none checked for you:

```bash
NAME=<name>
grep -l "^name: $NAME$" apps/*/docker-compose.yml                          # compose project
grep -rn "routers\.$NAME\.\|services\.$NAME\." apps/*/docker-compose.yml   # Traefik router/service
ls -d apps/$NAME 2>/dev/null                                               # infra dir
```

Any hit → **stop and ask for a different name.** Never append a suffix silently. Two
containers publishing the same `traefik.http.services.<name>` become two servers of one
load balancer, and requests for one host get answered by the other app.

## Phase 0 — Detect

Read `references/detect.md` and run every check. Report a short findings table before
touching anything: stack, services needed, PHP extensions, build-time env, health path,
and any template assumption this app breaks.

Do not skip checks because the app "looks standard". The worked example
(`apps/buduci-klasici/README.md`) looked standard and broke three template assumptions.

## Phase 1 — Ask

Ask **only** what detection cannot answer. Use AskUserQuestion, batched into one call.
Typical: the production domain; SSR yes/no when the framework supports it but it costs
RAM; memory limits when the box is tight. Never ask what a grep can answer.

Check RAM headroom before proposing an optional service — the VPS is 4GB and committed
limits already sit near it. `docker stats` on the VPS is the only real number; compose
limits are ceilings, not usage.

## Phase 2 — Scaffold the app repo

Read the stack reference: `references/laravel.md`, `references/nuxt.md`, or
`references/spa.md`. Copy from `templates/<stack>/` and **customise against Phase 0** —
drop services the app doesn't need, trim extensions it doesn't use, fix the frontend
stage if its build needs PHP.

Confirm the app's default branch matches the deploy workflow trigger (`master` vs `main`).

## Phase 3 — Scaffold the infrastructure

- `apps/<name>/docker-compose.yml` — production compose
- `apps/<name>/README.md` — per-app doc; shape in `references/handoff.md`
- `CLAUDE.md` — add the row to Current Apps, using the real host from the Traefik rule

**TLS — count the labels in the host.** A wildcard matches exactly one label. So
`app.phnx-solution.com` rides the default `origin.pem` and needs nothing, but
`api.app.phnx-solution.com` is **two** labels deep, outside both Cloudflare's Universal
SSL and the origin cert, and serves a 526.

This repo already hit it — commit `2a06db0`, *"flatten host to
unimaginable-api.phnx-solution.com for Universal SSL coverage"*. **Flatten the host to a
single label** (`app-api.phnx-solution.com`) rather than issuing a cert. Say so in Phase 1
if the domain the user asks for is multi-label; it's much cheaper to agree the hostname
before anything is built.

A separate zone (`megacatering.rs`) generally needs its own origin cert plus an entry in
`traefik/dynamic/tls.yml`. Not always, though: `unimaginable.rs` runs with `tls=true` and
no entry, which works only if that zone's Cloudflare SSL mode is Full rather than Full
(strict) — the edge then doesn't validate the origin cert. Check the zone's mode instead
of assuming either way.

## Phase 4 — Verify (mandatory, before any commit)

Follow `references/verify.md` in full. Build every target, run the stack, curl a real
page, run the probes. Report what was observed, not what was expected.

If verification is genuinely impossible (no Docker), say so plainly and stop. Never
commit unverified work and describe it as done.

## Phase 5 — Commit

Both repos, separately. Re-run `git status` and stage **only your own files by path** —
never `git add -A`. The user often has WIP in flight, and it may have changed since
Phase 0.

That guidance is necessary but **not sufficient**: `git add <path>` stages a whole file,
and this skill edits files a user may be sitting in (`bootstrap/app.php`,
`config/inertia.php`, `resources/js/app.ts`). Compare against the `git status --short`
taken in Phase 0 — if a file you edited was **already dirty then**, staging it commits
their work under your message. Stop and ask; offer `git add -p` and let them choose.

Match each repo's commit style (`git log`). Do not push: pushing the app repo triggers a
deploy, and the Phase 6 VPS prep hasn't happened yet.

## Phase 6 — Hand off

Read `references/handoff.md`. Produce, in this order:

1. **Absolute musts** — the ordered list only the user can do (infra push, VPS prep,
   DNS). Infra must be pushed and pulled *before* the app is pushed, or the deploy step
   dies on a missing `apps/<name>` directory.
2. **Secrets** — offer to run the `gh secret set` commands. Always pipe the SSH key from
   its file (`< ~/.ssh/key`); a mangled trailing newline is the most common deploy
   failure and produces a bare `ssh: handshake failed`.
3. **The `.env`** — the full file, with the silent-default traps called out
   (`references/env-contract.md`, Laravel-specific: its defaults are all
   production-wrong). Getting `DB_CONNECTION` wrong looks like a *successful* deploy.
   For Node apps the equivalent split is runtime `NUXT_*` vs build-time `VITE_*` —
   `references/nuxt.md`.
4. **The check that proves it** — stack-specific:
   - **Laravel**: `docker compose exec -T app php artisan about` — environment,
     database, cache, queue and session drivers in one shot.
   - **Nuxt/SPA**: the service is `web`, and there is no artisan.
     `docker compose exec -T web env | sort` for runtime vars, plus
     `curl -sI https://<domain>`. Anything baked at build time can only be confirmed by
     reading the built output or the page itself.
   - **Always**: `docker compose ps` — all healthy, nothing restarting. A restart loop
     is the loudest signal you have.

## Reference map

All paths below are relative to this skill's own directory
(`<infra>/.claude/skills/add-app/`) — note the infra repo also has an unrelated top-level
`scripts/`.

| File | Read when |
|---|---|
| `references/detect.md` | Phase 0, always |
| `references/laravel.md` | Laravel/Inertia apps; file→destination map, placeholders, the Inertia SSR contract |
| `references/nuxt.md` | Nuxt SSR apps |
| `references/spa.md` | Static / Vite SPA apps |
| `references/verify.md` | Phase 4, always |
| `references/env-contract.md` | Phase 6, and whenever a deploy "succeeds" but behaves wrong |
| `references/handoff.md` | Phase 6, always |
| `scripts/probe-proxy.php` | Phase 4, any Laravel app — proves proxy and signed-URL behaviour. Run it, don't read it. |
| `<infra>/templates/<stack>/README.md` | Phase 2 — the per-stack file list and what to customise |

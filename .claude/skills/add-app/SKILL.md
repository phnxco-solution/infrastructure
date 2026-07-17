---
name: add-app
description: Onboard a new website/app onto the shared Hostinger VPS — detect what the app actually needs, scaffold its Docker files, production compose and deploy workflow, verify the running stack locally, commit both repos, then hand back the exact manual steps and gh CLI commands. Use when adding a new app/website/service to the infrastructure, deploying an existing repo to the VPS for the first time, wiring an app into Traefik/MySQL/Redis, or when the user says "add a new app", "onboard this repo", "deploy this to the VPS", or invokes /add-app.
---

# Add an app to the shared VPS

Onboarding is not scaffolding. Copying template files is the easy part; the work is
**finding out what this particular app needs** and **proving the stack runs before it
reaches the VPS**. The files in `templates/` are sources, not a plan.

## Three rules

1. **Detect, don't assume.** Every claim about the app (needs a worker, needs intl,
   builds with Node alone) must come from a command whose output was actually seen. The
   template is a hypothesis, not evidence.
2. **Verify by running it.** A green build proves almost nothing — see
   `references/verify.md`. Do not commit before the stack serves a real page locally.
3. **Never commit a secret.** `.env` lives on the VPS only. A value needed at image
   build time is a build arg, not a baked file.

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

TLS: same-zone `*.phnx-solution.com` hosts ride the default `origin.pem` and need
nothing. A **separate zone** needs its own origin cert and an entry in
`traefik/dynamic/tls.yml`.

## Phase 4 — Verify (mandatory, before any commit)

Follow `references/verify.md` in full. Build every target, run the stack, curl a real
page, run the probes. Report what was observed, not what was expected.

If verification is genuinely impossible (no Docker), say so plainly and stop. Never
commit unverified work and describe it as done.

## Phase 5 — Commit

Both repos, separately. Before staging, run `git status` and stage **only your own files
by path** — the user often has WIP in flight and it may have changed mid-session. Never
`git add -A`.

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
   (`references/env-contract.md`). Getting `DB_CONNECTION` wrong looks like a
   *successful* deploy.
4. **The one check that proves it** — `docker compose exec -T app php artisan about`
   reports environment, database, cache, queue and session drivers in one shot.

## Reference map

| File | Read when |
|---|---|
| `references/detect.md` | Phase 0, always |
| `references/laravel.md` | Laravel/Inertia apps; includes the Inertia SSR contract |
| `references/nuxt.md` | Nuxt SSR apps |
| `references/spa.md` | Static / Vite SPA apps |
| `references/verify.md` | Phase 4, always |
| `references/env-contract.md` | Phase 6, and whenever a deploy "succeeds" but behaves wrong |
| `references/handoff.md` | Phase 6, always |
| `scripts/probe-proxy.php` | Any Laravel app — proves proxy and signed-URL behaviour |

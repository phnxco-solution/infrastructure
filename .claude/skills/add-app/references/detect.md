# Phase 0 — Detection

Every row below replaces an assumption with evidence. Run them, then report a findings
table. Cheap to run; each one has cost a real outage or a wrong deploy at least once.

## Contents

- [Identify the stack](#identify-the-stack)
- [Shared checks (every stack)](#shared-checks-every-stack)
- [Laravel checks](#laravel-checks)
- [Node/Nuxt/SPA checks](#nodenuxtspa-checks)
- [Findings table](#findings-table)

## Identify the stack

```bash
ls composer.json package.json nuxt.config.* vite.config.* index.html 2>/dev/null
```

- `composer.json` + `vite.config.*` → Laravel (`references/laravel.md`)
- `nuxt.config.*` → Nuxt SSR (`references/nuxt.md`)
- `vite.config.*`, no `composer.json` → SPA (`references/spa.md`)

Confirm the framework major from `composer.json` / `package.json`, don't infer it from
the folder name. Record it — it goes in the CLAUDE.md table row.

## Shared checks (every stack)

| Question | Command | Why it matters |
|---|---|---|
| Default branch | `git branch --show-current` | `deploy.yml` triggers on `master`. On `main` it silently never fires. |
| Remote exists | `git remote -v` | No remote → Actions can't run at all. |
| Already pushed? | `git rev-list --left-right --count origin/<br>...HEAD` | The user may have pushed mid-session, firing a deploy early. |
| Uncommitted WIP | `git status --short` | Never sweep it into your commit. Re-check right before staging. |
| Existing CI | `find .github -type f` | Don't clobber. Note stock starter-kit workflows — they often fail for reasons unrelated to deployment. |
| Build-time env | `grep -rn "import.meta.env.VITE_\|process.env.NUXT_PUBLIC_" resources/ app/ src/ 2>/dev/null` | **Each hit needs a build arg.** `.env` is not in the build context, so these bake in as empty and fail silently. |
| Package manager | `ls package-lock.json pnpm-lock.yaml yarn.lock` | A stray `pnpm-workspace.yaml` with no `pnpm-lock.yaml` means npm. Use the real lockfile. |
| Node version | app's CI workflow, `engines` in package.json | Pin it. `apk add nodejs` tracks Alpine and drifts (gave Node 24 when CI used 22). |
| Dev artifacts | `cat .gitignore` | Everything gitignored and locally present must be in `.dockerignore` — see below. |

### Dev artifacts that poison an image

Gitignored files are absent in CI but present in a local build. Any of these baked into
an image is a production bug:

| File | Symptom if baked in |
|---|---|
| `public/hot` | `Vite::isRunningHot()` true → app serves assets off `localhost:5173`. Site looks broken. |
| `public/build`, `.output`, `dist` | Stale assets shadow the fresh build. |
| `bootstrap/ssr` | Stale SSR bundle. |
| `.env` | Secrets in the image, and it overrides the injected environment. |

## Laravel checks

| Question | Command | Decision |
|---|---|---|
| **Worker needed?** | `grep -rl "implements ShouldQueue" app/` | No hits → **delete the worker service**. |
| **Scheduler needed?** | `grep -rn "Schedule::\|->everyMinute\|->daily(\|withSchedule" routes/console.php bootstrap/app.php app/` | No hits → **delete the scheduler service**. |
| **Does the Vite build need PHP?** | `grep -n "wayfinder\|laravel-vue-i18n" vite.config.*` | Any hit → the Node-only frontend stage **cannot build this app**. See `references/laravel.md`. |
| **Cross-check** | does the app's CI run `composer install` before `npm run build`? | If yes, the Docker build must too. Decisive tell. |
| **Inertia SSR?** | `grep -n "'enabled'" config/inertia.php`; `grep -n "build:ssr" package.json` | Enabled + a build:ssr script → SSR is on the table. Read the SSR contract in `references/laravel.md` before promising it. |
| **trustProxies?** | `grep -n "trustProxies" bootstrap/app.php` | **Missing → signed URLs 403 and rate limiters key on Traefik's IP.** Applies to every Laravel app here. Run `scripts/probe-proxy.php`. |
| **Health path** | `grep -n "health:" bootstrap/app.php` | Laravel's own endpoint (usually `/up`). The template's Traefik check uses nginx's `/health` — either is fine, be deliberate. |
| **Uploads?** | `grep -rn "Storage::\|->store(" app/` | No hits → nothing writes to `storage/app/public`, but the storage volume is still needed for **logs**. |

### PHP extensions — trim against evidence

The template installs gd, zip, bcmath, intl and DomPDF fonts. Most apps need none of them.
Keep `pdo_mysql, mbstring, xml, dom, pcntl, opcache` + `redis`; add the rest only on a hit:

```bash
grep -rn "Number::\|IntlDateFormatter\|NumberFormatter" app/ config/   # → intl
grep -rn "Intervention\|imagecreate\|->resize(" app/ config/           # → gd
grep -rn "ZipArchive\|Excel\|Dompdf\|Pdf::" app/ config/               # → zip (+ gd, fonts)
grep -rn "bcadd\|bcmul\|bcdiv\|bcsub" app/                             # → bcmath
```

`pcntl` is not optional if there's a worker — it handles SIGTERM.

## Node/Nuxt/SPA checks

| Question | Command | Decision |
|---|---|---|
| Server port | template compose / `nuxt.config` | Traefik `loadbalancer.server.port` must match (Nuxt: 3000). |
| Runtime env vs build env | `grep -rn "NUXT_PUBLIC_\|import.meta.env" .` | `NUXT_PUBLIC_*` are runtime; `VITE_*` bake in at build. Different failure modes. |
| DB access | `grep -rn "drizzle\|prisma\|mysql2" package.json` | Needs the `backend` network and DB env. |
| Static or server? | `nuxt.config` `ssr:`/`nitro.preset` | A prerendered site is nginx + a volume (like `unimaginable-landing`), not a Node service. |

## Findings table

Report before scaffolding. Example from the worked example:

```
Stack          Laravel 13 + Vue 3 + Inertia v3
Worker         YES — 6 Mailables implement ShouldQueue
Scheduler      NO  — no Schedule:: anywhere, app/Console/Commands empty
Frontend       NEEDS PHP + vendor — wayfinder shells out to `php artisan
               wayfinder:generate`; laravel-vue-i18n reads vendor/.../Translation/lang
               (CI confirms: composer install runs before npm run build)
SSR            available — config/inertia.php enabled, build:ssr works
Extensions     intl (Number::format in FormatsOdometer); NOT gd/zip/bcmath
Build env      VITE_APP_NAME → needs a build arg or titles render "Laravel"
trustProxies   MISSING → signed proposal links will 403 behind Traefik
Branch         master (matches deploy.yml)
Breaks         template frontend stage (Node-only), template .dockerignore
               (no public/hot)
```

Anything under `Breaks` is a template assumption this app violates — call it out to the
user explicitly, and fix it rather than working around it.

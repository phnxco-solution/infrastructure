# Phase 4 — Verify

Mandatory before committing. A green build is not verification: in the worked example
`build-and-push` succeeded in CI while SSR rendered the wrong language, every page title
said "Laravel", and every signed email link 403'd.

Report what was **observed**. "Should work" is not a result.

## Contents

- [1. Build every target](#1-build-every-target)
- [2. Inspect the image](#2-inspect-the-image)
- [3. Run the stack](#3-run-the-stack)
- [4. Probe](#4-probe)
- [5. Prove the failure modes](#5-prove-the-failure-modes)
- [6. Don't break their checks](#6-dont-break-their-checks)
- [Clean up](#clean-up)

## 1. Build every target

Which command depends on the layout Phase 2 produced. Look, don't assume — the
**unmodified Laravel template has no `nginx` target** (it ships `base, composer-deps,
frontend, development, production` plus a separate `Dockerfile.nginx`), so the collapsed
form below fails on it with `target stage "nginx" could not be found`:

```bash
grep -n "^FROM.*AS " docker/Dockerfile     # which targets exist?
ls docker/Dockerfile.nginx 2>/dev/null     # two-file layout?
```

**Namespace the tags per app.** Image tags are global to the daemon, so a fixed
`verify-production` survives a failed build and keeps pointing at whatever app you
onboarded last — every probe then passes green **against the wrong image**, and you
commit on the strength of it. Use `V="verify-<name>"` throughout:

```bash
V="verify-<name>"
```

**Two-file layout** — the template as shipped, correct when the frontend stage is
Node-only:

```bash
DOCKER_BUILDKIT=1 docker build -f docker/Dockerfile --target production -t "$V-production" .
DOCKER_BUILDKIT=1 docker build -f docker/Dockerfile.nginx -t "$V-nginx" .
```

**Collapsed layout** — one Dockerfile with `nginx`/`ssr` targets, needed when the build
needs PHP (`references/laravel.md`):

```bash
for t in production nginx ssr; do      # drop ssr unless SSR was chosen
  DOCKER_BUILDKIT=1 docker build -f docker/Dockerfile --target "$t" -t "$V-$t" . || exit 1
done
```

Note the `|| exit 1` — a bare `for` loop swallows a failed build and moves on. Then
confirm you're about to probe what you just built, not a survivor:

```bash
docker image inspect "$V-production" --format 'built {{.Created}}'   # must be seconds ago
```

If a probe result looks too good, check that timestamp before believing it.

**Nuxt** builds `--target production` from `docker/Dockerfile` — one image, and only ever
one. Even the sidecar shape (`apps/endlessly`) builds no nginx image: it runs stock
`nginx:1.27-alpine` with a config mounted from the infra repo.

**SPA** builds `-f docker/Dockerfile.nginx` only — there is no `docker/Dockerfile`.

Failures here are usually the frontend stage — see `references/laravel.md`.

## 2. Inspect the image

Confirm the build did what was claimed, rather than trusting exit 0:

```bash
docker run --rm "$V-production" sh -c '
  ls resources/js/routes resources/js/actions   # wayfinder actually generated?
  ls public/build/manifest.json                 # assets present?
  ls public/hot 2>&1                            # MUST be "No such file"
  ls bootstrap/ssr/app.js                       # SSR bundle, if SSR
  node -v; php -v | head -1                     # versions pinned as intended
'
```

## 3. Run the stack

Write a throwaway compose in the scratchpad, with the same **network aliases as
production** (`<app>-fpm`, `<app>-ssr`) — the aliases are part of what's being tested.

**Use MySQL, not sqlite**, even though sqlite would be one less container. Production is
MySQL 8.4, and migrations are exactly where the two diverge: anything MySQL-specific
(`fullText()`, JSON columns, generated columns, an `ALTER` sqlite can't do) either fails
here and reports a problem the app doesn't have, or passes here and fails on the VPS.
Verifying against a different engine than you deploy is how `migrate` reported 18
successful migrations into a throwaway sqlite file while the real database sat empty.

```yaml
name: verify-<name>              # not "verify" — two onboardings would reconcile each other
services:
  mysql:
    image: mysql:8.4             # same major as production
    environment:
      MYSQL_ROOT_PASSWORD: verify
      MYSQL_DATABASE: verify
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h127.0.0.1 -uroot -pverify --silent"]
      interval: 3s
      retries: 20
      start_period: 20s
  app:
    image: verify-<name>-production
    environment:
      CONTAINER_ROLE: app
      APP_ENV: production
      APP_KEY: base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
      APP_URL: http://localhost:8088
      APP_LOCALE: sr                # the app's real default
      DB_CONNECTION: mysql          # never sqlite — see above
      DB_HOST: mysql
      DB_DATABASE: verify
      DB_USERNAME: root
      DB_PASSWORD: verify
      SESSION_DRIVER: file          # cache/session aren't on the path being verified;
      CACHE_STORE: file             # skip the redis container
      QUEUE_CONNECTION: sync
      INERTIA_SSR_URL: http://<app>-ssr:13714
    depends_on:
      mysql: { condition: service_healthy }
    networks:
      default:
        aliases: [<app>-fpm]
    healthcheck:
      test: ["CMD-SHELL", "SCRIPT_NAME=/ping SCRIPT_FILENAME=/ping REQUEST_METHOD=GET cgi-fcgi -bind -connect 127.0.0.1:9000 | grep -q pong"]
      interval: 5s
      start_period: 10s
  nginx:
    image: verify-<name>-nginx
    ports: ["8088:80"]           # if taken, pick another and say which — don't kill the holder
    depends_on: { app: { condition: service_healthy } }
  ssr:
    image: verify-<name>-ssr
    networks:
      default:
        aliases: [<app>-ssr]
networks: { default: }
```

```bash
docker compose -f verify.yml up -d --wait --wait-timeout 120
docker compose -f verify.yml exec -T app php artisan migrate --force
docker compose -f verify.yml exec -T app php artisan about
curl -s -o home.html -w "HTTP %{http_code} | %{size_download} bytes\n" http://localhost:8088/
```

Read `about`'s **Drivers → Database** row and confirm it says `mysql`. If it says `sqlite`,
the app fell back and everything after it is meaningless — that is the exact failure this
stack exists to make impossible. Don't `grep | head` it: truncating past the row you came
for is how you get a green check that checked nothing.

Seed if the app's pages need data. An empty database renders a page that's technically 200
and proves very little (`apps/buduci-klasici`'s home page reads opening hours; with none,
there's nothing to look at).

## 4. Probe

**Is it actually server-rendered?** Strip `<script>` and count real text nodes. CSR
returns the `data-page` payload and an empty app root; SSR returns rendered markup:

```python
body = html.split('<body', 1)[1]
inner = re.sub(r'<script.*?</script>', '', body, flags=re.S)
text = [t.strip() for t in re.findall(r'>([^<>]{3,45})<', inner) if t.strip()]
# >5 nodes => SSR active. 0 => CSR fallback.
```

Check the `<title>` and `<html lang>` in the same response — that's where a baked-in
`VITE_APP_NAME` and the SSR locale bug both show up.

**Proxy behaviour** (every Laravel app): run this skill's `scripts/probe-proxy.php` inside
the app image. It must report the forwarded client IP, `isSecure: true` and
`hasValidSignature: true`.

| Exit | Meaning |
|---|---|
| 0 | PASS — proxy headers trusted |
| 1 | FAIL — the app is missing `trustProxies`, see `references/laravel.md` |
| 2 | **ABORT — the probe couldn't run.** Not a verdict about the app. Bad `APP_URL`, or the app wouldn't boot. Fix the invocation and re-run; don't "fix" the app. |

`APP_URL` **must be https** — signed URLs are generated from it, so an http one makes the
probe report a failure that isn't real. It aborts rather than lie. `APP_KEY` isn't needed
(signing and verification use the same key, whatever it is).

The script lives in the **infra** repo, not the app repo, so mount it by absolute path.
`$PWD` here is the app repo, and Docker will silently create an empty *directory* for a
bind-mount source that doesn't exist, giving you a baffling "Could not open input file":

```bash
SKILL=<infra-repo>/.claude/skills/add-app          # absolute
docker run --rm -e APP_URL=https://<domain> \
  -v "$SKILL/scripts/probe-proxy.php:/tmp/probe.php:ro" \
  "$V-production" php /tmp/probe.php
```

Read the **exit code**, not the tail of the output — and don't pipe it through `tail`,
which replaces the status with `tail`'s own. That mistake has already produced a
confident "exit 0" from a failed build twice today.

**Config resolution** — prove each env var you introduced actually lands:

```bash
docker run --rm -e INERTIA_SSR_URL=http://x-ssr:13714 "$V-production" \
  php artisan tinker --execute="dump(config('inertia.ssr'), (new Inertia\Ssr\BundleDetector)->detect());"
```

> Rebuild before probing. A stale image is the likeliest cause of a confusing result —
> if a config change appears not to have taken, check that first.

## 5. Prove the failure modes

Claims made in a compose comment or a summary must be tested, not assumed:

```bash
docker compose -f verify.yml stop ssr
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8088/   # must be 200 (CSR fallback)
docker compose -f verify.yml start ssr                            # and recovers
```

## 6. Don't break their checks

App-code edits are sometimes unavoidable (trustProxies, SSR locale, env-driven config).
Any edit means running the app's own gates before committing:

```bash
npx vue-tsc --noEmit && npx eslint <changed files> && php artisan test
```

Run these against the tree as it stands at commit time — the user may have committed
work mid-session.

## Clean up — on every exit, not just success

This runs after a failed build and an aborted session too. A half-finished onboarding
leaves more behind than a finished one.

```bash
docker compose -f verify.yml down -v
docker rmi -f "$V-production" "$V-nginx" "$V-ssr" 2>/dev/null
```

Then **say what you're leaving behind that git won't surface**:

- **Edits to the user's application code** — `trustProxies` in `bootstrap/app.php`, the
  `config/inertia.php` env change, the SSR locale fix in `app.ts`. Their code, uncommitted,
  mixed into their tree, and they didn't ask for it. Name them by path. Bailing out while
  silently leaving `bootstrap/app.php` modified is worse than changing nothing at all.
- **Build artifacts** (`bootstrap/ssr/`, `public/build/`) — gitignored and harmless.
  Mention them; don't `rm -rf` them.

If port 8088 is taken, pick another and say which — never kill whatever holds it.

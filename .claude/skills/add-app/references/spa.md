# Static / Vite SPA apps

Source files: `templates/spa/`. Live examples: `apps/unimaginable-app` (built image),
`apps/unimaginable-landing` (plain nginx + a volume, no image at all).

> Less battle-tested than `references/laravel.md`. Read off the templates and the
> deployed composes. The Phase 0 and Phase 4 protocols are stack-agnostic — run them.

## Shape

One service, `web`: nginx serving `dist/`, built into the image.

```
web  ->  nginx:1.27-alpine  ->  :80  ->  traefik-public
```

Named `web`, not `nginx`, so its alias on the shared `traefik-public` network doesn't
collide with every other project's `nginx`. Keep the name. 64M is plenty.

Two-stage build: `node:22-alpine` runs `npm ci && npm run build`, then the result is
copied into nginx. Confirm the build output directory — the template copies `/app/dist`,
which is Vite's default but not universal (`vite.config` `build.outDir`).

## What goes where

`templates/spa/README.md` has the file list. This template is the smallest — **no
`docker/Dockerfile`, no `docker/entrypoint.sh`, no local-dev `docker-compose.yml`**; the
image builds from `docker/Dockerfile.nginx` alone. Two things to know first:

- **`docker/docker-compose.prod.yml` → `<infra>/apps/<name>/docker-compose.yml`.** A
  template file landing in the *infra* repo under a different name, not copied into the
  app repo. Phase 3 depends on it.
- **Three placeholders, not two.** `{{APP_NAME}}` and `{{APP_DOMAIN}}` in the compose and
  workflow, plus **`{{BACKEND_HOST}}` in `nginx.conf`** — see below. Prove none survive
  with `grep -rn "{{[A-Z_]*}}" docker/ .github/ <infra>/apps/<name>/`. Greping for
  Laravel's two returns clean while `{{BACKEND_HOST}}` ships.

## Two variants

| Variant | When | Shape |
|---|---|---|
| **Built image** | The SPA has a build step and its own repo | `templates/spa/` as-is; deploy workflow builds and pushes one image |
| **Files in a volume** | A hand-maintained static site | No image, no build, no deploy workflow. `nginx:1.27-alpine` with `/opt/volumes/apps/<name>/public:/usr/share/nginx/html:ro`. See `apps/unimaginable-landing`. |

Don't scaffold a build pipeline for a site that's three HTML files. Ask which it is if
detection is ambiguous.

## Backend proxy — `{{BACKEND_HOST}}`

`templates/spa/docker/nginx.conf` has a third placeholder beyond name and domain. An SPA
that talks to an API in this cluster proxies `/api` and `/storage` **same-origin** to
that API's nginx container, rather than calling it cross-origin:

```
unimaginable-app  ->  /api, /storage  ->  unimaginable-nginx-1:80
```

`{{BACKEND_HOST}}` is that upstream. **It must be the container name
(`unimaginable-nginx-1:80`), never the service name.** Service names are not unique on
`traefik-public` — five projects publish `nginx` and four publish `web`, so `nginx:80`
round-robins across five tenants and would proxy most of this app's API traffic into
other people's containers. Container names (`<project>-<service>-1`) are unique.

Check which network actually connects the two, and don't just copy `apps/unimaginable-app`:
its `backend` membership is a red herring — `unimaginable`'s nginx is on `default` +
`traefik-public`, not `backend`, so that proxy works over `traefik-public`.

**This placeholder fails silently, unlike Laravel's.** It's quoted in the config
(`set $backend_upstream "{{BACKEND_HOST}}";`), so nginx parses it happily, the container
starts, and the site serves. Only `/api` and `/storage` break — at runtime, on a DNS
lookup for a host literally named `{{BACKEND_HOST}}`. Nothing in a build, a healthcheck
or a homepage curl catches it, so **curl an API route in Phase 4**, not just `/`.

Establish which shape applies in Phase 0 — `grep -rn "VITE_API\|axios\|fetch(" src/` and
look at whether URLs are relative (`/api/...`, proxied) or absolute (cross-origin, and
then baked in at build time). For a pure static SPA, strip the proxy blocks out of
`nginx.conf` rather than leaving them pointing at nothing.

## The thing that actually bites

**Everything is baked at build time.** An SPA has no server, so there is no runtime env
at all — every `import.meta.env.VITE_*` is frozen into the bundle when the image is
built. `.env` on the VPS does nothing for it.

Grep every `VITE_*` in Phase 0 and give each one a build arg in the Dockerfile and the
deploy workflow. A wrong API base URL here is invisible until the browser makes a
request to the wrong host.

`.dockerignore` must exclude `dist` and `public/hot` — a stale local `dist` copied in
over the fresh build is a silent regression.

## nginx config

The template's `nginx.conf` provides `/health` (Traefik's check) and the SPA history
fallback. If the app uses client-side routing, confirm the fallback exists, or a deep
link reloads into a 404:

```nginx
location / {
    try_files $uri $uri/ /index.html;
}
```

## Verification

`references/verify.md`, minus the php-fpm and proxy probes. Run the image, `curl /` and
`curl /health`, and **curl a deep client-side route** to prove the history fallback.
Confirm the baked-in `VITE_*` values are the production ones — grep the built JS in the
image for the API host if in doubt. That's the check that catches an SPA pointed at
localhost.

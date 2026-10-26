#!/usr/bin/env bash
# Releases one commit on the VPS. .github/workflows/deploy.yml pipes this script over SSH,
# prefixed with REGISTRY_USER and REGISTRY_TOKEN (the job's own short-lived token), so no
# secret reaches a command line or a file:
#
#   bash -s -- <commit sha>
#
# Everything runs inside main(), so bash has read the whole script before the first command:
# docker compose run forwards stdin and would otherwise swallow the lines after it.
set -euo pipefail

images=(ghcr.io/phnxco-solution/{{APP_NAME}})
registry_config=

main() {
    local commit="$1"

    # Pull with the job's token in a throwaway Docker config, leaving the VPS's own GHCR login alone.
    registry_config=$(mktemp -d)
    trap 'rm -rf "$registry_config"' EXIT
    printf '%s' "$REGISTRY_TOKEN" \
        | DOCKER_CONFIG="$registry_config" docker login ghcr.io -u "$REGISTRY_USER" --password-stdin >/dev/null
    for image in "${images[@]}"; do
        DOCKER_CONFIG="$registry_config" docker pull --quiet "$image:$commit"
        docker tag "$image:$commit" "$image:latest"
    done

    cd /opt/infrastructure/apps/{{APP_NAME}}

    # Ensure log directory exists with correct ownership
    mkdir -p /opt/volumes/apps/{{APP_NAME}}/logs

    # Run migrations using new image while old container still serves traffic. The
    # one-off container carries the web health check without a server, so
    # autoheal=False keeps autoheal from killing a slow migration.
    docker compose run --rm -T --label autoheal=False web ./node_modules/.bin/drizzle-kit migrate

    # Recreate app, wait for healthy
    docker compose up -d --wait --wait-timeout 60 --remove-orphans

    docker compose ps
    docker image prune -af --filter "until=168h"
}

main "$@"

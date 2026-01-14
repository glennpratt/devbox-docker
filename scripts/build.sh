#!/usr/bin/env bash
set -xeuo pipefail

PROJECT_DIR=$(realpath "$1")
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

IMAGE_NAME=devbox-builder
STAGE_DOCKERFILE="$DIR/Dockerfile"
NIX_SYSTEM="x86_64-linux"

VOLUME_STORE=devbox-nix-store
VOLUME_CACHE=devbox-nix-cache

echo "Creating docker volumes (if missing)..."
docker volume create "$VOLUME_STORE" >/dev/null || true
docker volume create "$VOLUME_CACHE" >/dev/null || true

export DOCKER_DEFAULT_PLATFORM=linux/amd64

docker buildx build --load --file "$STAGE_DOCKERFILE" -t "$IMAGE_NAME" "$DIR"

docker run --rm -it \
  --mount "type=volume,source=$VOLUME_STORE,target=/nix" \
  --mount "type=volume,source=$VOLUME_CACHE,target=/root/.cache/nix" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PROJECT_DIR":/project \
  --workdir /project \
  "$IMAGE_NAME" \
  bash -lc "set -euo pipefail; \
    devbox install \
    && nix build /builder#packages.$NIX_SYSTEM.dockerImage \
    && eval \"\$(devbox global shellenv)\" \
    && skopeo copy --insecure-policy docker-archive:./result docker-daemon:devbox-example:latest"

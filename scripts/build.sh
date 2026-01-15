#!/usr/bin/env bash
set -xeuo pipefail

PROJECT_DIR=$(realpath "$1")
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

IMAGE_NAME=devbox-builder
STAGE_DOCKERFILE="$DIR/Dockerfile"

VOLUME_CACHE=devbox-nix-cache

echo "Creating docker cache volume (if missing)..."
docker volume create "$VOLUME_CACHE" >/dev/null || true

export DOCKER_DEFAULT_PLATFORM=linux/amd64

docker buildx build --load --file "$STAGE_DOCKERFILE" -t "$IMAGE_NAME" "$DIR"

docker run --rm -it \
  --mount "type=volume,source=$VOLUME_CACHE,target=/root/.cache/nix" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PROJECT_DIR":/project \
  --workdir /project \
  -e NIX_BINARY_CACHE_DIR=/root/.cache/nix/binary-cache \
  "$IMAGE_NAME" --name devbox-example --tag latest

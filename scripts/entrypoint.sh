#!/usr/bin/env bash
set -euo pipefail

# Default values
IMAGE_NAME="devbox-app"
IMAGE_TAG="latest"
PUSH=""
REGISTRY=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --name)
      IMAGE_NAME="$2"
      shift 2
      ;;
    --tag)
      IMAGE_TAG="$2"
      shift 2
      ;;
    --push)
      PUSH="true"
      shift
      ;;
    --registry)
      REGISTRY="$2"
      shift 2
      ;;
    --help|-h)
      cat <<EOF
Build a layered Docker image from a devbox project.

Usage:
  docker run --rm \\
    -v /var/run/docker.sock:/var/run/docker.sock \\
    -v \$(pwd):/project \\
    devbox-nix-builder [OPTIONS]

Options:
  --name NAME      Name for the output image (default: devbox-app)
  --tag TAG        Tag for the output image (default: latest)
  --push           Push to registry after building
  --registry URL   Registry to push to (e.g., ghcr.io/user)
  --help           Show this help message

Examples:
  # Build with default name
  docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v \$(pwd):/project devbox-nix-builder

  # Build with custom name and tag
  docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v \$(pwd):/project devbox-nix-builder --name myapp --tag v1.0

  # Build and push to registry
  docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v \$(pwd):/project devbox-nix-builder --name myapp --push --registry ghcr.io/myuser

For faster builds, mount Nix store volumes:
  docker run --rm \\
    -v /var/run/docker.sock:/var/run/docker.sock \\
    -v \$(pwd):/project \\
    -v devbox-nix-store:/nix \\
    -v devbox-nix-cache:/root/.cache/nix \\
    devbox-nix-builder --name myapp
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Detect system architecture from devbox flake
NIX_SYSTEM="x86_64-linux"

echo "==> Installing devbox packages..."
devbox install

echo "==> Building Docker image with Nix..."
nix build /builder#packages.${NIX_SYSTEM}.dockerImage \
  --extra-experimental-features 'nix-command flakes fetch-closure'

# Determine the full image reference
if [[ -n "$REGISTRY" ]]; then
  FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
else
  FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"
fi

echo "==> Loading image as ${FULL_IMAGE}..."
eval "$(devbox global shellenv)" 2>/dev/null || true
skopeo copy --insecure-policy docker-archive:./result "docker-daemon:${FULL_IMAGE}"

echo "==> Successfully built: ${FULL_IMAGE}"

# Push if requested
if [[ -n "$PUSH" ]]; then
  if [[ -z "$REGISTRY" ]]; then
    echo "Error: --push requires --registry"
    exit 1
  fi
  echo "==> Pushing to registry..."
  skopeo copy --insecure-policy "docker-daemon:${FULL_IMAGE}" "docker://${FULL_IMAGE}"
  echo "==> Successfully pushed: ${FULL_IMAGE}"
fi

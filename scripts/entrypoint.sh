#!/usr/bin/env bash
set -euo pipefail

# Default values
IMAGE_NAME="devbox-app"
IMAGE_TAG="latest"
PUSH=""
REGISTRY=""
GITHUB_ACTIONS=""

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
    --github-actions)
      GITHUB_ACTIONS="true"
      shift
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
  --name NAME         Name for the output image (default: devbox-app)
  --tag TAG           Tag for the output image (default: latest)
  --push              Push to registry after building
  --registry URL      Registry to push to (e.g., ghcr.io/user)
  --github-actions    Build with GitHub Actions compatibility (adds ~15MB)
  --help              Show this help message

Examples:
  # Build with default name
  docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v \$(pwd):/project devbox-nix-builder

  # Build with custom name and tag
  docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v \$(pwd):/project devbox-nix-builder --name myapp --tag v1.0

  # Build and push to registry
  docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v \$(pwd):/project devbox-nix-builder --name myapp --push --registry ghcr.io/myuser

For faster builds, mount a cache volume:
  docker run --rm \\
    -v /var/run/docker.sock:/var/run/docker.sock \\
    -v \$(pwd):/project \\
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

# Fix for git ownership issues in Nix cache (common in GHA with UID mismatches)
git config --global --add safe.directory '*'

# Add binary cache if configured
if [[ -n "${NIX_BINARY_CACHE_DIR:-}" ]]; then
  echo "==> Using binary cache at ${NIX_BINARY_CACHE_DIR}..."
  # Configure Nix to use the local cache globally (affects devbox install and nix build)
  # keeping upstream as fallback
  CURRENT_SUBSTITUTERS=$(nix show-config --extra-experimental-features 'nix-command flakes' | grep '^substituters =' | cut -d'=' -f2 | xargs)
  export NIX_CONFIG="substituters = file://${NIX_BINARY_CACHE_DIR} ${CURRENT_SUBSTITUTERS}
require-sigs = false"
  mkdir -p "${NIX_BINARY_CACHE_DIR}"
fi

echo "==> Installing devbox packages..."
devbox install

echo "==> Building Docker image with Nix..."
# Determine which image output to build
if [[ -n "$GITHUB_ACTIONS" ]]; then
  echo "    Building with GitHub Actions compatibility..."
  IMAGE_OUTPUT="ghaCompatImage"
else
  IMAGE_OUTPUT="dockerImage"
fi

# Detect the most common nixpkgs revision from devbox.lock
# This minimizes package version bloat by matching common packages that don't
# require precise versions to devbox package dependencies. This can be aided
# by the user choosing to use NixOS channel versions instead of explicit package
# versions in devbox.json. e.g. "github:NixOS/nixpkgs/nixos-25.05#bashInteractive"
# instead of "bashInteractive@5.2.16"
NIXPKGS_OVERRIDE=()
if [[ -f devbox.lock ]]; then
  # Extract nixpkgs revisions from resolved URLs that have a # (package selector)
  # Format: "github:NixOS/nixpkgs/<rev>?...#<pkg>" or "github:NixOS/nixpkgs/<rev>#<pkg>"
  MOST_COMMON_REV=$(jq -r '
    .packages | to_entries[]
    | select(.value.resolved != null)
    | .value.resolved
    | select(contains("#"))
    | capture("github:NixOS/nixpkgs/(?<rev>[^?#]+)")
    | .rev
  ' devbox.lock 2>/dev/null | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')

  if [[ -n "$MOST_COMMON_REV" ]]; then
    echo "    Detected nixpkgs revision: $MOST_COMMON_REV"
    NIXPKGS_OVERRIDE=(--override-input nixpkgs "github:NixOS/nixpkgs/$MOST_COMMON_REV")
  fi
fi

# Build command - pure evaluation with optional nixpkgs override
nix build /builder#packages.${NIX_SYSTEM}.${IMAGE_OUTPUT} \
  --extra-experimental-features 'nix-command flakes fetch-closure' \
  "${NIXPKGS_OVERRIDE[@]}" \
  --print-build-logs

# Determine the full image reference
if [[ -n "$REGISTRY" ]]; then
  FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
else
  FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"
fi

echo "==> Loading image as ${FULL_IMAGE}..."
skopeo copy --insecure-policy docker-archive:./result "docker-daemon:${FULL_IMAGE}"


echo "==> Successfully built: ${FULL_IMAGE}"

# Copy to cache if configured
if [[ -n "${NIX_BINARY_CACHE_DIR:-}" ]]; then
  echo "==> Copying build closure to cache..."
  nix copy --to "file://${NIX_BINARY_CACHE_DIR}" /builder#packages.${NIX_SYSTEM}.dockerImage
  nix copy --to "file://${NIX_BINARY_CACHE_DIR}" /builder#packages.${NIX_SYSTEM}.cache
fi

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

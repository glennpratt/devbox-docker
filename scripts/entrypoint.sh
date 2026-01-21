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
  mkdir -p "${NIX_BINARY_CACHE_DIR}"
  echo "==> Using binary cache at ${NIX_BINARY_CACHE_DIR}..."

  TRUSTED_KEYS=""
  if [[ -f /root/.cache/nix/cache-pub.key ]]; then
    echo "    Found public key for cache verification."
    TRUSTED_KEYS="trusted-public-keys = $(cat /root/.cache/nix/cache-pub.key) cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
  fi

  # Configure Nix to use the local cache globally (affects devbox install and nix build)
  if [[ "${DEBUG_OFFLINE:-0}" == "1" ]]; then
    echo "==> DEBUG_OFFLINE: Blocking cache.nixos.org and using local cache only..."
    echo "127.0.0.1 cache.nixos.org" >> /etc/hosts
    export NIX_CONFIG="substituters = file://${NIX_BINARY_CACHE_DIR}
require-sigs = false
${TRUSTED_KEYS}"
  else
    # Keep upstream as fallback
    CURRENT_SUBSTITUTERS=$(nix config show --extra-experimental-features 'nix-command flakes' | grep '^substituters =' | cut -d'=' -f2 | xargs)
    export NIX_CONFIG="substituters = file://${NIX_BINARY_CACHE_DIR} ${CURRENT_SUBSTITUTERS}
require-sigs = false
${TRUSTED_KEYS}"
  fi
fi

if [[ "${VERBOSE:-0}" == "1" ]]; then
    echo "==> Environment Check"
    echo "    NIX_CONFIG: $NIX_CONFIG"
    export DEVBOX_DEBUG=1
fi

echo "==> Installing devbox packages..."
devbox install

echo "==> Extracting environment variables from devbox..."
# Capture the full environment from devbox. We use --pure to avoid capturing
# the builder's own environment, ensuring the target image is clean.
# We also map the host-side project path to /project for the final image.
PROJECT_ROOT=$(pwd)
ENV_FULL=$(devbox run --pure printenv 2>/dev/null | sed "s|$PROJECT_ROOT|/project|g" || true)

if [[ -n "$ENV_FULL" ]]; then
  # 1. Extract PATH and identify additions (everything except standard system paths)
  # We exclude standard paths that the Docker image provides itself.
  PATH_FULL=$(echo "$ENV_FULL" | grep '^PATH=' | cut -d= -f2-)
  PATH_ADDITIONS=$(echo "$PATH_FULL" | tr ':' '\n' | \
    grep -vE '^(/bin|/usr/bin|/usr/local/bin|/usr/sbin|/sbin|/root/.nix-profile/bin)$' | \
    tr '\n' ':' | sed 's/:$//')

  # 2. Extract other variables, filtering out system junk and devbox internal noise.
  # We also filter out variables that are set explicitly in flake.nix (like USER).
  ENV_VARS=$(echo "$ENV_FULL" | grep -v '^PATH=' | \
    grep -vE '^(USER|HOME|PWD|TERM|SHELL|SHLVL|_|DEBIAN_FRONTEND|NIX_.*|DEVBOX_.*_HASH|__DEVBOX_.*|IMAGE_NAME)=' || true)

  # Add PATH_ADDITIONS to the result if any were found
  if [[ -n "$PATH_ADDITIONS" ]]; then
      ENV_VARS="${ENV_VARS}
PATH_ADDITIONS=${PATH_ADDITIONS}"
  fi
fi

if [[ -n "$ENV_VARS" ]]; then
  echo "    Found environment variables from init_hook:"
  echo "$ENV_VARS" | sed 's/^/      /'
fi

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

# Write extracted environment variables to JSON file for flake to read
# Format: ["NAME=value", "NAME2=value2"]
if [[ -n "$ENV_VARS" ]]; then
  echo "$ENV_VARS" | jq -R -s 'split("\n") | map(select(length > 0))' > /project/.devbox-env-vars.json
else
  echo "[]" > /project/.devbox-env-vars.json
fi

# Build command - requires --impure to read the env vars file
nix build /builder#packages.${NIX_SYSTEM}.${IMAGE_OUTPUT} \
  --extra-experimental-features 'nix-command flakes fetch-closure' \
  "${NIXPKGS_OVERRIDE[@]}" \
  --impure \
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
    PUSH_URI="file://${NIX_BINARY_CACHE_DIR}"
    if [[ -f "/root/.cache/nix/cache-priv.key" ]]; then
        echo "    Signing cache with secret key."
        PUSH_URI="${PUSH_URI}?secret-key=/root/.cache/nix/cache-priv.key"
    else
        echo "    Warning: No secret key found, pushing without signing."
    fi

    nix_copy=(nix copy)
    if [[ "${VERBOSE:-0}" == "1" ]]; then
        nix_copy+=(-v)
    fi

    "${nix_copy[@]}" --to "$PUSH_URI" /builder#packages.${NIX_SYSTEM}.${IMAGE_OUTPUT}

    # Dynamically cache all build dependencies (derivation closure outputs)
    echo "==> Caching full build closure (including build-time dependencies)..."
    DRV_PATH=$(nix eval --raw --extra-experimental-features "nix-command flakes" /builder#packages.${NIX_SYSTEM}.${IMAGE_OUTPUT}.drvPath)

    nix-store -qR "$DRV_PATH" \
      | xargs nix-store -q --outputs \
      | xargs -n 1000 sh -c 'for p; do [ -e "$p" ] && echo "$p"; done' _ \
      | xargs -r "${nix_copy[@]}" --to "$PUSH_URI" || echo "Warning: Failed to copy some paths to cache"
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

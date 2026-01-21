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

echo "==> Extracting environment variables from devbox init_hook..."

# Optimized "one-pass" extraction:
# Prepend an environment dump to the init_hook to capture the "before" state,
# then capture the "after" state from the final `devbox run printenv` output.
ENV_VARS=""
if [[ -f devbox.json ]] && jq -e '.shell.init_hook' devbox.json >/dev/null 2>&1; then
  # Save original config
  cp devbox.json devbox.json.orig

  # Inject an environment dump at the start of the init_hook
  # Handling both string and array formats for init_hook
  jq '.shell.init_hook |= if type == "string" then "printenv > /tmp/env_before; " + . else ["printenv > /tmp/env_before"] + . end' devbox.json.orig > devbox.json

  echo "    Running devbox printenv (single pass)..."
  # Capture final env (after hook) while the hook itself dumps the before env
  ENV_AFTER_HOOK=$(devbox run --pure printenv 2>/dev/null | sort)

  if [[ -f /tmp/env_before ]]; then
    ENV_BEFORE_HOOK=$(sort /tmp/env_before)
    rm -f /tmp/env_before
  else
    # Fallback if the injection failed for some reason
    ENV_BEFORE_HOOK=$(sort <(printenv))
  fi

  # Restore original config
  cp devbox.json.orig devbox.json
  rm -f devbox.json.orig

  # Find variables that are new or changed (excluding PATH)
  # Filter out internal devbox/nix noise
  ENV_VARS=$(comm -13 <(echo "$ENV_BEFORE_HOOK") <(echo "$ENV_AFTER_HOOK") | \
    grep -v '^PATH=' | \
    grep -v '^__DEVBOX_' | \
    grep -v '^DEVBOX_.*_HASH=' || true)

  # Handle PATH specially - extract the new path components that were added
  PATH_WITH=$(echo "$ENV_AFTER_HOOK" | grep '^PATH=' | cut -d= -f2-)
  PATH_WITHOUT=$(echo "$ENV_BEFORE_HOOK" | grep '^PATH=' | cut -d= -f2-)

  if [[ "$PATH_WITH" != "$PATH_WITHOUT" ]]; then
    # Find path components in PATH_WITH that aren't in PATH_WITHOUT
    NEW_PATH_COMPONENTS=$(comm -23 \
      <(echo "$PATH_WITH" | tr ':' '\n' | sort) \
      <(echo "$PATH_WITHOUT" | tr ':' '\n' | sort) | \
      tr '\n' ':' | sed 's/:$//')

    if [[ -n "$NEW_PATH_COMPONENTS" ]]; then
      ENV_VARS="${ENV_VARS}
PATH_ADDITIONS=${NEW_PATH_COMPONENTS}"
    fi
  fi

  # Trim empty lines and whitespace
  ENV_VARS=$(echo "$ENV_VARS" | grep -v '^$' | sed 's/[[:space:]]*$//' || true)
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

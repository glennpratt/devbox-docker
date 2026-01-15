#!/usr/bin/env bash
# Detect duplicate packages in a Docker image's /nix/store
# Usage: ./detect-duplicates.sh [image-name:tag]

set -euo pipefail

IMAGE="${1:-devbox-docker-example:latest}"

echo "==> Checking for duplicate packages in $IMAGE..."

# Extract package names (strip the hash prefix) and find duplicates
# Store paths look like: <hash>-<name>-<version>
duplicates=$(docker run --rm "$IMAGE" ls /nix/store/ 2>/dev/null | \
  grep -v '^\.' | \
  sed 's/^[a-z0-9]*-//' | \
  sort | uniq -d || true)

if [[ -n "$duplicates" ]]; then
  echo ""
  echo "⚠️  WARNING: Found duplicate packages (same name, different store hashes):"
  echo ""

  while IFS= read -r pkg; do
    echo "  📦 $pkg"
    # Show the actual store paths for this package
    docker run --rm "$IMAGE" ls -1 /nix/store/ 2>/dev/null | grep "$pkg" | sed 's/^/      /'
  done <<< "$duplicates"

  echo ""
  echo "These duplicates may indicate packages built from different nixpkgs revisions."
  echo "Consider pinning all devbox packages to the same nixpkgs release (e.g., nixos-25.11)."
  exit 1
else
  echo "✅ No duplicate packages found"
fi

FROM jetpackio/devbox-root-user:latest

# Configure Nix
RUN echo filter-syscalls = false >> /etc/nix/nix.conf && \
    echo experimental-features = nix-command fetch-closure flakes >> /etc/nix/nix.conf && \
    echo download-buffer-size = 4294967296 >> /etc/nix/nix.conf

# Install additional tools: updated nix, skopeo for image copying, jq for JSON parsing
# We use the EXACT same commit as flake.nix's nixpkgs-build to ensure cache hits.
# SHA: 77ef7a29d276c6d8303aece3444d61118ef71ac2 (nixos-25.11)
RUN nix-env -f https://github.com/nixos/nixpkgs/archive/77ef7a29d276c6d8303aece3444d61118ef71ac2.tar.gz -iA nix skopeo jq && \
    nix-collect-garbage --delete-old -d

# Prime the cache: Build a dummy layered image using the pinned infrastructure.
# This forces the download/realization of python3, flake8, stdenv, and all other
# build-time dependencies of dockerTools.buildLayeredImage.
RUN nix-build -E 'with import (fetchTarball "https://github.com/nixos/nixpkgs/archive/77ef7a29d276c6d8303aece3444d61118ef71ac2.tar.gz") {}; dockerTools.buildLayeredImage { name = "warmup"; contents = [ hello ]; }' && \
    nix-collect-garbage -d

# Ensure Nix profile binaries are in PATH
ENV PATH="/root/.nix-profile/bin:${PATH}"

# Copy the flake template and entrypoint
COPY flake.nix /builder/
COPY scripts/entrypoint.sh /builder/entrypoint.sh

WORKDIR /project

ENTRYPOINT ["/builder/entrypoint.sh"]

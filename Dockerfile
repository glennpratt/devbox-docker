FROM jetpackio/devbox-root-user:latest

# Configure Nix
RUN echo filter-syscalls = false >> /etc/nix/nix.conf && \
    echo experimental-features = nix-command fetch-closure flakes >> /etc/nix/nix.conf && \
    echo download-buffer-size = 4294967296 >> /etc/nix/nix.conf

# Install additional tools: updated nix, skopeo for image copying
RUN nix-env --install --file '<nixpkgs>' --attr nix cacert -I nixpkgs=channel:nixpkgs-unstable && \
    nix-env -iA nixpkgs.skopeo && \
    nix-collect-garbage --delete-old -d

# Ensure Nix profile binaries are in PATH
ENV PATH="/root/.nix-profile/bin:${PATH}"

# Copy the flake template and entrypoint
COPY flake.nix /builder/
COPY scripts/entrypoint.sh /builder/entrypoint.sh

WORKDIR /project

ENTRYPOINT ["/builder/entrypoint.sh"]

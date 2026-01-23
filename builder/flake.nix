{
  description = "Build the devbox-docker builder image using Nix";

  inputs = {
    # Pin nixpkgs for reproducibility and layer reuse
    nixpkgs.url = "github:NixOS/nixpkgs/2c3e5ec5df46d3aeee2a1da0bfedd74e21f4bf3a";
  };

  outputs =
    { self, nixpkgs }:
    let
      # Always x86_64-linux since we build inside a Linux container
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # The base image with Determinate Nix
      # Passed via BASE_IMAGE_TAR environment variable
      baseImagePath = builtins.getEnv "BASE_IMAGE_TAR";
      baseImage = if baseImagePath != "" then baseImagePath else null;

      # Packages to include in the builder
      builderPackages = [
        # pkgs.nix # Removed to use Determinate Nix from base image
        pkgs.skopeo
        pkgs.jq
        pkgs.devbox
        pkgs.git
        pkgs.bashInteractive
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.gnused
        pkgs.gawk
        pkgs.findutils
      ];


      # Create builder files that will be accessible at /builder in the container
      # We need to create the files with the path structure that matches where they'll appear
      builderFlake = pkgs.writeText "flake.nix" (builtins.readFile ../flake.nix);
      builderEntrypoint = pkgs.writeScript "entrypoint.sh" (builtins.readFile ../scripts/entrypoint.sh);

      # Prime the Nix cache by pre-building dockerTools dependencies
      # This ensures layer reuse when building user images
      warmupImage = pkgs.dockerTools.buildLayeredImage {
        name = "warmup";
        contents = [ pkgs.hello ];
      };

    in
    {
      packages.${system} = {
        # The layered builder image
        builderImage = pkgs.dockerTools.buildLayeredImage {
          name = "devbox-docker-builder";
          tag = "latest";

          # Layer on top of Determinate Nix base
          fromImage = baseImage;

          contents = builderPackages ++ [
            pkgs.dockerTools.binSh
            pkgs.dockerTools.caCertificates
            pkgs.dockerTools.usrBinEnv
          ];

          extraCommands = ''
            # Create working directory and temp directories
            mkdir -p project
            mkdir -p -m 1777 tmp
            mkdir -p -m 1777 var/tmp

            # Create /builder directory with the flake and entrypoint
            # These need to be at /builder so entrypoint.sh can find them
            mkdir -p builder
            cp ${builderFlake} builder/flake.nix
            cp ${builderEntrypoint} builder/entrypoint.sh
            chmod +x builder/entrypoint.sh

            # Nix configuration for single-user mode in containers
            mkdir -p etc/nix
            cat > etc/nix/nix.conf << 'EOF'
            sandbox = false
            filter-syscalls = false
            experimental-features = nix-command fetch-closure flakes
            download-buffer-size = 4294967296
            build-users-group =
            EOF
          '';

          config = {
            Cmd = [ "/bin/bash" ];
            Entrypoint = [ "/builder/entrypoint.sh" ];
            WorkingDir = "/project";
            Env = [
              "PATH=/root/.nix-profile/bin:/nix/var/nix/profiles/default/bin:/bin:/usr/bin"
              "NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
            ];
          };
        };

        # Convenience: just the warmup derivation for cache priming
        warmup = warmupImage;
      };

      defaultPackage.${system} = self.packages.${system}.builderImage;
    };
}

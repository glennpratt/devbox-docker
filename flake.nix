{
  description = "Build a layered docker image using packages from a generated devbox flake";

  inputs = {
    # Use the same nixpkgs as devbox to avoid duplicate dependencies
    devbox-gen.url = "path:/project/.devbox/gen/flake";
  };

  outputs = { self, devbox-gen, ... }:
    let
      system = builtins.head (builtins.attrNames devbox-gen.devShells);
      # Reuse devbox's nixpkgs to ensure all packages use the same versions
      pkgs = devbox-gen.inputs.nixpkgs.legacyPackages.${system};

      # Get the dynamic linker path for this system
      dynamicLinker = "${pkgs.glibc}/lib/ld-linux-x86-64.so.2";

      # Base packages for all images
      baseContents = [
          pkgs.bashInteractive
          pkgs.coreutils
          pkgs.dockerTools.binSh
          pkgs.dockerTools.caCertificates
          pkgs.dockerTools.fakeNss
          pkgs.dockerTools.usrBinEnv
          # Use devShell inputs from the generated devbox flake
        ] ++ (devbox-gen.devShells.${system}.default.buildInputs or []);

      # Additional packages for GitHub Actions compatibility
      ghaContents = [
          # glibc for dynamic linker compatibility
          pkgs.glibc
          # C++ standard library (libstdc++) for Node.js
          pkgs.stdenv.cc.cc.lib
          # tar and gzip for actions/checkout
          pkgs.gnutar
          pkgs.gzip
        ];

      # Build image with specified contents and optional GHA support
      buildImage = { includeGHA }: pkgs.dockerTools.buildLayeredImage {
        name = "devbox-example";
        tag = "latest";

        # No base image - pure Nix for minimal size
        contents = baseContents ++ (if includeGHA then ghaContents else []);

        # Create /lib64 symlink for glibc dynamic linker compatibility (GHA only)
        extraCommands = if includeGHA then ''
          mkdir -p lib64
          ln -sf ${dynamicLinker} lib64/ld-linux-x86-64.so.2
        '' else "";

        config = {
          Cmd = [ "/bin/bash" "-l" ];
          Env = [
            "USER=root"
            "PATH=/bin:/usr/bin"
            "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
          ] ++ (if includeGHA then [
            # Make dynamic linker search /lib64 for libraries
            "LD_LIBRARY_PATH=/lib64"
          ] else []);
        };
      };
    in
    {
      packages.${system} = {
        # Minimal image without GitHub Actions support
        dockerImage = buildImage { includeGHA = false; };

        # Image with GitHub Actions compatibility
        ghaCompatImage = buildImage { includeGHA = true; };

        # Manifest of all packages to be cached
        cache = pkgs.symlinkJoin {
          name = "devbox-cache";
          paths = baseContents ++ ghaContents;
        };
      };

      defaultPackage.${system} = self.packages.${system}.dockerImage;
    };
}

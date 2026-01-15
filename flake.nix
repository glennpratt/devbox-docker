{
  description = "Build a layered docker image using packages from a generated devbox flake";

  inputs = {
    # Use the same nixpkgs as devbox to avoid duplicate dependencies
    devbox-gen.url = "path:/project/.devbox/gen/flake";
  };

  outputs =
    { self, devbox-gen, ... }:
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
      ] ++ (devbox-gen.devShells.${system}.default.buildInputs or [ ]);

      # Additional packages for GitHub Actions compatibility
      ghaContents = [
        # nix-ld: shim dynamic linker for executing FHS binaries (like GHA's node)
        pkgs.nix-ld
        # Dependencies that GHA's node binary needs to find via nix-ld
        pkgs.glibc
        pkgs.stdenv.cc.cc.lib
        pkgs.zlib
        pkgs.openssl
        # Tools for actions/checkout
        pkgs.gnutar
        pkgs.gzip
        # SSH for actions that use deploy keys or ssh-agent
        pkgs.openssh
      ];

      # Build image with specified contents and optional GHA support
      buildImage =
        { includeGHA }:
        let
          # Only add GHA contents if requested
          finalContents = baseContents ++ (if includeGHA then ghaContents else [ ]);

          # NIX_LD_LIBRARY_PATH: libraries to be found by nix-ld for FHS binaries
          nixLdLibraryPath = pkgs.lib.makeLibraryPath [
            pkgs.glibc
            pkgs.stdenv.cc.cc.lib
            pkgs.zlib
            pkgs.openssl
          ];

          # Create /lib64/ld-linux-x86-64.so.2 symlink pointing to nix-ld
          # This intercepts execution of FHS binaries (using standard linker path)
          # and routes them through nix-ld, which sets up the environment correctly.
          finalExtraCommands =
            if includeGHA then
              ''
                mkdir -p lib64
                ln -sf ${pkgs.nix-ld}/libexec/nix-ld lib64/ld-linux-x86-64.so.2
              ''
            else
              "";

          # Only set special Env if requested
          finalEnv = [
            "USER=root"
            "PATH=/bin:/usr/bin"
            "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
          ] ++ (if includeGHA then [
            "NIX_LD=${dynamicLinker}"
            "NIX_LD_LIBRARY_PATH=${nixLdLibraryPath}"
          ] else []);
        in
        pkgs.dockerTools.buildLayeredImage {
          name = "devbox-example";
          tag = "latest";

          # No base image - pure Nix for minimal size
          contents = finalContents;

          # Create /lib64 symlink for glibc dynamic linker compatibility (GHA only)
          extraCommands = finalExtraCommands;

          config = {
            Cmd = [
              "/bin/bash"
              "-l"
            ];
            Env = finalEnv;
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

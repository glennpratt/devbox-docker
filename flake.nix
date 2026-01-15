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

      # Read devbox.lock to find the most common nixpkgs revision
      # This ensures pkgs.* packages use the same nixpkgs as devbox packages
      devboxLock = builtins.fromJSON (builtins.readFile /project/devbox.lock);

      # Extract nixpkgs revisions from resolved package URLs
      # Format: "github:NixOS/nixpkgs/<rev>#<pkg>" or "github:NixOS/nixpkgs/<rev>?..."
      extractRevision = resolved:
        let
          # Remove "github:NixOS/nixpkgs/" prefix
          afterPrefix = builtins.substring 27 (builtins.stringLength resolved) resolved;
          # Find the end of revision (# or ? or end of string)
          hashPos = let p = builtins.match "([^#?]+).*" afterPrefix;
                    in if p == null then afterPrefix else builtins.head p;
        in hashPos;

      # Get all resolved URLs that are from nixpkgs AND have a package selector (#)
      # This filters out base nixpkgs entries that don't reference specific packages
      resolvedUrls = builtins.filter
        (url: builtins.substring 0 27 url == "github:NixOS/nixpkgs/" &&
              builtins.match ".*#.*" url != null)
        (builtins.map
          (pkg: pkg.resolved or "")
          (builtins.attrValues devboxLock.packages));

      # Extract revisions and count occurrences
      revisions = builtins.map extractRevision resolvedUrls;

      # Count occurrences of each revision
      countRevision = rev: builtins.length (builtins.filter (r: r == rev) revisions);

      # Find the most common revision (simple approach: pick first one with highest count)
      uniqueRevisions = builtins.attrNames (builtins.listToAttrs
        (builtins.map (r: { name = r; value = true; }) revisions));

      mostCommonRev =
        if builtins.length uniqueRevisions == 0
        then null
        else builtins.head (builtins.sort
          (a: b: countRevision a > countRevision b)
          uniqueRevisions);

      # Fetch the most common nixpkgs, or fall back to devbox-gen's nixpkgs
      nixpkgsSource =
        if mostCommonRev == null
        then devbox-gen.inputs.nixpkgs
        else builtins.fetchTarball {
          url = "https://github.com/NixOS/nixpkgs/archive/${mostCommonRev}.tar.gz";
        };

      # Use the detected nixpkgs for all packages
      pkgs =
        if mostCommonRev == null
        then devbox-gen.inputs.nixpkgs.legacyPackages.${system}
        else (import nixpkgsSource { inherit system; });

      # Get the dynamic linker path for this system
      dynamicLinker = "${pkgs.glibc}/lib/ld-linux-x86-64.so.2";

      # Base packages for all images
      # Note: We get curl/yq-go from the same pkgs to ensure all dependencies share
      # the same nixpkgs revision. Using devbox-gen.devShells.buildInputs would pull
      # in transitive dependencies from the wrong nixpkgs revision.
      baseContents = [
        pkgs.bashInteractive
        pkgs.coreutils
        pkgs.dockerTools.binSh
        pkgs.dockerTools.caCertificates
        pkgs.dockerTools.fakeNss
        pkgs.dockerTools.usrBinEnv
        # Add devbox packages directly from the unified pkgs
        pkgs.curl
        pkgs.yq-go
      ];

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

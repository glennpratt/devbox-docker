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

      imageContents = [
          pkgs.bashInteractive
          pkgs.coreutils
          pkgs.dockerTools.binSh
          pkgs.dockerTools.caCertificates
          pkgs.dockerTools.fakeNss
          pkgs.dockerTools.usrBinEnv
          # glibc for dynamic linker compatibility (GitHub Actions, etc.)
          pkgs.glibc
          # C++ standard library (libstdc++) for Node.js and other tools
          pkgs.stdenv.cc.cc.lib
          # Use devShell inputs from the generated devbox flake
        ] ++ (devbox-gen.devShells.${system}.default.buildInputs or []);
    in
    {
      packages.${system} = {
        dockerImage = pkgs.dockerTools.buildLayeredImage {
          name = "devbox-example";
          tag = "latest";

          # No base image - pure Nix for minimal size
          contents = imageContents;

          # Create /lib64 symlink for glibc dynamic linker compatibility
          # This allows external binaries (e.g., GitHub Actions' Node.js) to run
          # Using extraCommands instead of fakeRootCommands to avoid needing proot
          extraCommands = ''
            mkdir -p lib64
            ln -sf ${dynamicLinker} lib64/ld-linux-x86-64.so.2
          '';

          config = {
            Cmd = [ "/bin/bash" "-l" ];
            Env = [
              "USER=root"
              "PATH=/bin:/usr/bin"
              "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
            ];
          };
        };

        # Manifest of all packages to be cached
        cache = pkgs.symlinkJoin {
          name = "devbox-cache";
          paths = imageContents;
        };
      };

      defaultPackage.${system} = self.packages.${system}.dockerImage;
    };
}

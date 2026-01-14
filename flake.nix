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
    in
    {
      packages.${system}.dockerImage = pkgs.dockerTools.buildLayeredImage {
        name = "devbox-example";
        tag = "latest";

        # No base image - pure Nix for minimal size
        contents = [
          pkgs.bashInteractive
          pkgs.coreutils
          pkgs.dockerTools.binSh
          pkgs.dockerTools.caCertificates
          pkgs.dockerTools.fakeNss
          pkgs.dockerTools.usrBinEnv
          # Use devShell inputs from the generated devbox flake
        ] ++ (devbox-gen.devShells.${system}.default.buildInputs or []);

        config = {
          Cmd = [ "/bin/bash" "-l" ];
          Env = [
            "USER=root"
            "PATH=/bin:/usr/bin"
            "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
          ];
        };
      };

      defaultPackage.${system} = self.packages.${system}.dockerImage;
    };
}

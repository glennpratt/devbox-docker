# Devbox to Layered Nix Docker Images

Convert any project with a `devbox.json` into a cache-friendly, layered Docker image using pure Nix—**without shipping devbox in the final image**.

## Why This Exists

Building Docker images with devbox directly creates one massive layer (3GB+ in some projects) because all Nix store paths get bundled together. This tool uses Nix's `dockerTools.buildLayeredImage` to create proper, cache-friendly layers where each Nix package becomes its own layer.

**Result**: A 41-layer, **137MB** pure-Nix image instead of a single 3GB+ monolithic layer.

## Quick Start

### Using the Published Builder Image

```bash
# Build your devbox project into a Docker image
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v $(pwd):/project \
  devbox-nix-builder:latest --name myapp --tag v1.0

# Run your new image
docker run --rm myapp:v1.0
```

### With Nix Store Caching (Faster Rebuilds)

```bash
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v $(pwd):/project \
  -v devbox-nix-store:/nix \
  -v devbox-nix-cache:/root/.cache/nix \
  devbox-nix-builder:latest --name myapp --tag v1.0
```

### Options

```
--name NAME      Name for the output image (default: devbox-app)
--tag TAG        Tag for the output image (default: latest)
--push           Push to registry after building
--registry URL   Registry to push to (e.g., ghcr.io/user)
--help           Show help message
```

## How It Works

1. **Mount your project** with `devbox.json` at `/project`
2. **Build**: The builder runs `devbox install` to generate the Nix flake, then builds a layered Docker image using `dockerTools.buildLayeredImage`
3. **Load**: The image is loaded directly into your Docker daemon via the mounted socket

The key innovation is using the devbox-generated flake's packages directly:

```nix
contents = [
  pkgs.bashInteractive
  pkgs.coreutils
  # ... base utilities
] ++ (devbox-gen.devShells.${system}.default.buildInputs or []);
```

## Build Output

The build produces a layered Docker image with:
- **41 separate layers** (for the example project with curl + yq)
- **~137MB total size** (pure Nix, no base image)
- Proper layer caching—changing one package only invalidates that layer

## Building the Builder Image

If you want to build the builder image yourself:

```bash
# Clone this repo
git clone https://github.com/yourname/devbox-docker
cd devbox-docker

# Build the builder image
docker buildx build --load -t devbox-nix-builder:latest .

# Test with the example
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v $(pwd)/example:/project \
  devbox-nix-builder:latest --name example-app
```

## Example Project

The `example/` directory contains a minimal devbox project:

```json
{
  "packages": ["curl@latest", "yq-go@latest"]
}
```

## Architecture

### Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Builder image with devbox + nix + skopeo |
| `flake.nix` | Nix flake that creates the layered Docker image |
| `scripts/entrypoint.sh` | Build orchestration script |
| `example/devbox.json` | Example devbox project |

### Build Flow

```
┌─────────────────────────────────────────────────────────────────┐
│  Your Machine                                                   │
│                                                                 │
│  docker run -v $(pwd):/project devbox-nix-builder               │
│         │                                                       │
│         ▼                                                       │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  devbox-nix-builder container                           │    │
│  │                                                         │    │
│  │  1. devbox install                                      │    │
│  │     └── generates .devbox/gen/flake                     │    │
│  │                                                         │    │
│  │  2. nix build /builder#dockerImage                      │    │
│  │     └── buildLayeredImage with devbox packages          │    │
│  │                                                         │    │
│  │  3. skopeo copy → docker-daemon                         │    │
│  │     └── loads image via mounted docker.sock             │    │
│  └─────────────────────────────────────────────────────────┘    │
│         │                                                       │
│         ▼                                                       │
│  myapp:v1.0 available in your Docker                            │
└─────────────────────────────────────────────────────────────────┘
```

## Volume Strategy

For faster rebuilds, use Docker volumes to cache the Nix store:

```bash
# Create volumes once
docker volume create devbox-nix-store
docker volume create devbox-nix-cache

# Use them in builds
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v $(pwd):/project \
  -v devbox-nix-store:/nix \
  -v devbox-nix-cache:/root/.cache/nix \
  devbox-nix-builder:latest

# Cleanup (to force fresh builds)
docker volume rm devbox-nix-store devbox-nix-cache
```

## Known Limitations

1. **x86_64 only**: Currently hardcoded to build `x86_64-linux` images. ARM support requires changes.

2. **macOS testing**: When testing the built image on macOS/ARM, use `DOCKER_DEFAULT_PLATFORM=linux/amd64`.

3. **Image name in Nix**: The image name baked by Nix is `devbox-example`; the `--name` flag re-tags it after build.

## CI/CD

This repository includes GitHub Actions workflows:

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `test.yml` | Pull requests | Tests the full build flow without publishing |
| `publish-builder.yml` | Push to main | Publishes the builder image to GHCR |
| `publish-example.yml` | Push to main | Uses the builder to publish the example (dogfooding) |

### Using in Your Own Project

Add this workflow to your project to build on every push:

```yaml
name: Build Docker Image

on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      packages: write
    steps:
      - uses: actions/checkout@v4
      
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      
      - name: Build with devbox-nix-builder
        run: |
          docker run --rm \
            -v /var/run/docker.sock:/var/run/docker.sock \
            -v ${{ github.workspace }}:/project \
            -v devbox-nix-cache:/root/.cache/nix \
            ghcr.io/OWNER/devbox-docker-builder:latest \
            --name ghcr.io/${{ github.repository }} \
            --tag ${{ github.sha }}

> [!CAUTION]
> **Do not mount a host directory over `/nix` in CI.**
> The builder image contains pre-installed tools (like `skopeo` and `nix`) in its `/nix` store. Mounting a host directory over `/nix` will hide these tools and cause the build to fail. For faster builds, cache the download directory `/root/.cache/nix` instead.
      
      - run: docker push ghcr.io/${{ github.repository }}:${{ github.sha }}
```

## Next Steps

- [x] ~~Publish builder image to a public registry~~ (via GitHub Actions)
- [x] ~~Add CI integration example~~ (see CI/CD section)
- [ ] Support ARM builds (aarch64-linux)
- [ ] Support customizing which packages from devbox are included

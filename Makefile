.PHONY: fmt build build-gha builder base builder-nix clean-cache

# For now, we're only interested in x86_64
export DOCKER_DEFAULT_PLATFORM=linux/amd64

# Use a fixed cache path under TMPDIR (occasionally cleared on most OS)
NIX_CACHE_DIR ?= $(TMPDIR)devbox-nix-cache
# Base image tarball location
BASE_IMAGE_TAR ?= $(PWD)/devbox-nix-base.tar
IMAGE_NAME ?= devbox-builder-nix

fmt:
	nixfmt flake.nix builder/flake.nix

# Original Dockerfile-based builder (legacy)
builder:
	docker buildx build --load --file Dockerfile -t devbox-builder .

# Minimal Determinate Nix base image
base:
	docker buildx build --load --file Dockerfile.base -t devbox-nix-base .
	docker save devbox-nix-base -o $(BASE_IMAGE_TAR)

# Nix-built layered builder image (uses base image)
# Runs nix build inside the base container since macOS cannot build Linux derivations directly
builder-nix: base
	docker run --rm \
		-v $(PWD):/workspace \
		-v $(NIX_CACHE_DIR):/root/.cache/nix \
		-w /workspace \
		devbox-nix-base \
		sh -c 'BASE_IMAGE_TAR=/workspace/devbox-nix-base.tar nix build ./builder#builderImage \
			--extra-experimental-features "nix-command flakes" \
			--impure \
			--print-build-logs \
			&& cp -L result /workspace/builder-result.tar.gz'
	gunzip -f builder-result.tar.gz
	docker load -i builder-result.tar
	docker tag devbox-docker-builder:latest devbox-builder-nix:latest
	rm -f builder-result.tar

$(NIX_CACHE_DIR)/cache-priv.key:
	@mkdir -p $(NIX_CACHE_DIR)
	@if [ ! -f $@ ]; then \
		echo "Generating Nix signing keys..."; \
		nix key generate-secret --key-name devbox-docker-cache > $(NIX_CACHE_DIR)/cache-priv.key; \
		nix key convert-secret-to-public < $(NIX_CACHE_DIR)/cache-priv.key > $(NIX_CACHE_DIR)/cache-pub.key; \
	fi

build: builder $(NIX_CACHE_DIR)/cache-priv.key
	@mkdir -p $(NIX_CACHE_DIR)
	docker run --rm \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v $(PWD)/example:/project \
		-v $(NIX_CACHE_DIR):/root/.cache/nix \
		-e NIX_BINARY_CACHE_DIR=/root/.cache/nix/binary-cache \
		devbox-builder --name devbox-docker-example --tag latest

build-gha: builder $(NIX_CACHE_DIR)/cache-priv.key
	@mkdir -p $(NIX_CACHE_DIR)
	docker run --rm \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v $(PWD)/example:/project \
		-v $(NIX_CACHE_DIR):/root/.cache/nix \
		-e NIX_BINARY_CACHE_DIR=/root/.cache/nix/binary-cache \
		devbox-builder --name devbox-docker-example --tag latest --github-actions

clean-cache:
	rm -rf $(NIX_CACHE_DIR)

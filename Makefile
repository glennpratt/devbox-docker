.PHONY: fmt build build-gha builder clean-cache

# For now, we're only interested in x86_64
export DOCKER_DEFAULT_PLATFORM=linux/amd64

# Use a fixed cache path under TMPDIR (occasionally cleared on most OS)
NIX_CACHE_DIR ?= $(TMPDIR)devbox-nix-cache

fmt:
	nixfmt flake.nix

builder:
	docker buildx build --load --file Dockerfile -t devbox-builder .

build: builder
	@mkdir -p $(NIX_CACHE_DIR)
	docker run --rm \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v $(PWD)/example:/project \
		-v $(NIX_CACHE_DIR):/root/.cache/nix \
		devbox-builder --name devbox-docker-example --tag latest

build-gha: builder
	@mkdir -p $(NIX_CACHE_DIR)
	docker run --rm \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v $(PWD)/example:/project \
		-v $(NIX_CACHE_DIR):/root/.cache/nix \
		devbox-builder --name devbox-docker-example --tag latest --github-actions

clean-cache:
	rm -rf $(NIX_CACHE_DIR)

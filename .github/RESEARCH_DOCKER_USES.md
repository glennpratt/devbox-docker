# Research: GitHub Actions `uses: docker://` Pattern

## Summary

The `uses: docker://` pattern in GitHub Actions can be used as an alternative to manually running `docker run` commands. This research investigates what is automatically mounted, how configs are passed, and whether it could replace the current approach in our workflows.

## Key Findings

### 1. Automatically Mounted Directories

When using `uses: docker://image`, GitHub Actions automatically mounts:

- **`/github/workspace`**: The repository code (from `actions/checkout`). This is also the default working directory.
- **`/github/home`**: Temporary home directory for the container user.
- **`/github/workflow`**: Contains workflow-related files, including `/github/workflow/event.json` with the full event payload.
- **`/github/file_commands`**: Internal GHA communication files for `GITHUB_ENV`, `GITHUB_PATH`, `GITHUB_OUTPUT`.
- **`/github/runner_temp`**: Temporary runner directory.
- **`/var/run/docker.sock`**: **Docker socket is automatically mounted!** This is critical for our use case.

### 2. Environment Variables

All standard `GITHUB_*` environment variables are automatically passed to the container:
- `GITHUB_WORKSPACE`, `GITHUB_SHA`, `GITHUB_REPOSITORY`, `GITHUB_REF`, etc.
- `RUNNER_OS`, `RUNNER_TEMP`, `RUNNER_WORKSPACE`, etc.
- Any variables defined in the `env:` block at step or job level
- Inputs from `with:` are passed as `INPUT_*` variables (e.g., `with: my_var: val` → `INPUT_MY_VAR=val`)

### 3. Arguments

Arguments are passed via the `with.args` field and are appended to the container's entrypoint.

Example:
```yaml
- uses: docker://alpine:latest
  with:
    args: sh -c "echo hello"
```

### 4. Working Directory

The default working directory is **`/github/workspace`**, regardless of any `WORKDIR` in the Dockerfile.

### 5. Docker Socket Access

**Critical finding**: The Docker socket `/var/run/docker.sock` is **automatically mounted** when using `uses: docker://`.

From our test run, the actual `docker run` command used by GHA includes:
```
-v "/var/run/docker.sock":"/var/run/docker.sock"
```

This means containers can build and manipulate Docker images, which is exactly what our builder needs.

## Comparison: `uses: docker://` vs `run: docker run`

| Feature | `uses: docker://...` | `run: docker run ...` |
|---------|---------------------|----------------------|
| **Mounts** | Automatic (`/github/workspace`, `/github/home`, etc.) | Manual (must use `-v` flags) |
| **Docker Socket** | ✅ Automatically mounted | ❌ Must manually add `-v /var/run/docker.sock:/var/run/docker.sock` |
| **Env Vars** | ✅ Automatic (`GITHUB_*`, `INPUT_*`, `env:` block) | ❌ Manual (must use `-e` or `--env-file`) |
| **Working Dir** | ✅ Automatic (`/github/workspace`) | ❌ Manual (must use `-w` or rely on Dockerfile) |
| **Permissions** | ✅ Automatically handles UID/GID mapping | ⚠️ Often causes permission issues |
| **Flexibility** | ⚠️ Limited (cannot add custom flags like `--privileged`) | ✅ Full control over Docker command line |
| **Cache Volumes** | ❌ Cannot mount custom volumes directly | ✅ Can mount any volume (e.g., `-v devbox-nix-cache:/root/.cache/nix`) |
| **Integrations** | ✅ Easy output via `GITHUB_OUTPUT` | ⚠️ Requires manual file handling |

## Limitations of `uses: docker://`

1. **No custom volume mounts**: You cannot specify additional volumes like cache directories.
2. **No custom Docker options**: Cannot use flags like `--privileged`, `--cap-add`, custom `--network`, etc.
3. **Step-level only**: This syntax only works for individual steps, not for wrapping the pattern in a custom action without creating an `action.yml`.

## Workarounds for Limitations

### For Custom Volumes (like Nix cache):
Use **job-level containers** instead:
```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    container:
      image: ghcr.io/user/builder:latest
      volumes:
        - /var/run/docker.sock:/var/run/docker.sock
        - devbox-nix-cache:/root/.cache/nix
    steps:
      - uses: actions/checkout@v4
      - run: ./build.sh
```

### For Custom Docker Options:
Create a **custom Docker container action** with an `action.yml`:
```yaml
# action.yml
name: 'My Builder'
description: 'Build with custom options'
runs:
  using: 'docker'
  image: 'docker://ghcr.io/user/builder:latest'
  options: --privileged -v /custom:/mount
```

## Critical Limitations Discovered

During testing, we discovered two significant limitations of the `uses: docker://` pattern:

### 1. No Expression Support in Image Reference

**The `uses: docker://` field does NOT support GitHub Actions expressions.**

This means you cannot use:
```yaml
uses: docker://ghcr.io/${{ github.repository }}-builder:test  # ❌ FAILS
```

You must use literal values:
```yaml
uses: docker://ghcr.io/glennpratt/devbox-docker-builder:test  # ✅ Works
```

**Impact**: This makes the pattern less reusable across forks or different repositories. You'd need to hardcode the repository name.

### 2. Image Must Be in a Registry

**The `uses: docker://` pattern ALWAYS tries to pull the image from a registry.**

This means:
- ❌ Cannot use locally-built images (e.g., `devbox-nix-builder:test`)
- ✅ Must push to a registry first (e.g., `ghcr.io/user/image:tag`)

**Impact**: You must add an extra step to push the builder image to GHCR before you can use it with `uses: docker://`. This adds time and complexity.

Example:
```yaml
- name: Build builder
  run: make builder-nix IMAGE_NAME=builder TAG=test

- name: Push to registry for uses: docker://
  run: |
    docker tag builder:test ghcr.io/user/builder:test
    docker push ghcr.io/user/builder:test

- uses: docker://ghcr.io/user/builder:test  # Now it can pull it
  with:
    args: --name app --tag latest
```

These limitations significantly reduce the appeal of the `uses: docker://` pattern for this use case.

## Application to Our Project

### Current Approach (`.github/workflows/test.yml`)
```yaml
- name: Test building the example
  run: |
    docker run --rm \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v ${{ github.workspace }}/example:/project \
      -v ${{ runner.temp }}/nix-cache:/root/.cache/nix \
      -e NIX_BINARY_CACHE_DIR=/root/.cache/nix/store \
      devbox-nix-builder:test \
      --name test-app --tag test
```

### Can We Use `uses: docker://`?

**Yes, we can!** The perceived blockers are not actually blockers:

#### ✅ Cache Volumes
**Blocker claimed**: Cannot mount custom volumes like the Nix cache.  
**Reality**: We can use a cache directory within `/github/workspace`, which is automatically mounted:

```yaml
- name: Set up cache
  run: mkdir -p .nix-cache

- name: Restore cache
  uses: actions/cache@v4
  with:
    path: .nix-cache
    key: nix-${{ hashFiles('devbox.json', 'devbox.lock') }}

- uses: docker://devbox-nix-builder:test
  with:
    args: --name test-app --tag test
  env:
    NIX_BINARY_CACHE_DIR: /github/workspace/.nix-cache/store
```

#### ✅ Project Location
**Blocker claimed**: Need to mount project at `/project`.  
**Reality**: The entrypoint uses `PROJECT_ROOT=$(pwd)`, so it works from any directory. With `uses: docker://`, the working directory is `/github/workspace` where the code is checked out.

For repos where the devbox project is at the root (like `kpp-services`), this works perfectly as-is.

For repos with the project in a subdirectory (like our `example/`), you'd need to either:
- Move files to root before building, OR
- Add a `--project-dir` argument to the entrypoint

#### ✅ Docker Options
**Blocker claimed**: Cannot use custom Docker options.  
**Reality**: We don't actually use any custom Docker options. The Docker socket is automatically mounted.

### Comparison for kpp-services Use Case

**Current (docker run)**:
```yaml
- name: Build image using devbox-docker
  run: |
    docker run --rm \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v ${{ github.workspace }}/${{ env.CHECKOUT_PATH }}:/project \
      -v ${{ runner.temp }}/nix-cache:/root/.cache/nix \
      -e NIX_BINARY_CACHE_DIR=/root/.cache/nix/store \
      ghcr.io/glennpratt/devbox-docker-builder:c80514c \
      --github-actions \
      --name "$TAG_PREFIX" \
      --tag latest
```

**Potential (uses: docker://)**: 
```yaml
- name: Set up Nix cache
  run: mkdir -p .nix-cache

- name: Restore cache
  uses: actions/cache@v4
  with:
    path: .nix-cache
    key: nix-${{ hashFiles('devbox.json', 'devbox.lock') }}

- name: Build image
  uses: docker://ghcr.io/glennpratt/devbox-docker-builder:c80514c
  with:
    args: --github-actions --name "${{ env.TAG_PREFIX }}" --tag latest
  env:
    NIX_BINARY_CACHE_DIR: /github/workspace/.nix-cache/store

- name: Fix cache permissions
  if: always()
  run: sudo chown -R $(id -u):$(id -g) .nix-cache
```

### Trade-offs

| Aspect | `docker run` | `uses: docker://` |
|--------|--------------|-------------------|
| **Clarity** | ✅ Explicit mounts visible | ⚠️ Implicit mounts (need to know GHA behavior) |
| **Verbosity** | ⚠️ Long command | ✅ Cleaner syntax |
| **Debugging** | ✅ Can copy exact command | ⚠️ Harder to reproduce locally |
| **Flexibility** | ✅ Can mount anywhere | ⚠️ Limited to workspace |
| **Cache location** | ✅ Can use `${{ runner.temp }}` | ⚠️ Must use workspace (counts toward disk quota) |
| **Local testing** | ✅ Easy to test locally | ⚠️ Requires understanding GHA mounts |
| **Maintenance** | ⚠️ More lines to maintain | ✅ Simpler |

## Recommendation (Updated After Testing)

**Use `docker run` for this project.** The `uses: docker://` pattern has too many limitations:

### Critical Blockers for `uses: docker://`:

1. **Image must pre-exist in registry**: GitHub Actions pulls the image at job start, BEFORE any steps run. You cannot build and then use the image in the same job with `uses: docker://`.

2. **No expression support**: Cannot use `${{ github.repository }}` or other expressions in the image reference, making it less portable.

3. **Hardcoded image names**: Must use literal values, reducing reusability across forks.

4. **Extra push step required**: Must push images to a registry even for testing, adding time and complexity.

### When `uses: docker://` Makes Sense:

The pattern works well for:
- **Pre-published actions**: Images that are already in a registry (e.g., `docker://alpine:latest`)
- **Stable tools**: Linters, formatters, or other tools that don't change per-build
- **Simple workflows**: Where you're not building the image in the same workflow

### For This Project:

**Test workflow**: Must use `docker run` because we build the builder image in the same workflow.

**kpp-services**: Could potentially use `uses: docker://` IF:
- You reference a pre-published builder image (e.g., `ghcr.io/glennpratt/devbox-docker-builder:latest`)
- You're okay with hardcoding the repository name
- The builder image is stable and doesn't change frequently

However, even for kpp-services, `docker run` is probably better because:
- ✅ More explicit and easier to debug
- ✅ Can use `${{ runner.temp }}` for cache (off disk quota)
- ✅ Portable across forks
- ✅ Can easily test with different builder versions

### Final Verdict:

**Stick with `docker run`**. The perceived benefits of `uses: docker://` (cleaner syntax) are outweighed by:
- Cannot build and use image in same workflow
- No expression support
- Less flexibility
- Harder to debug
- Must push to registry even for testing

The explicit `docker run` approach is more powerful, more flexible, and actually clearer about what's happening.

## Test Results

From workflow run `21274565863`:

### `uses: docker://alpine:latest` step:
- ✅ Docker socket present: `srw-rw---- 1 root 118 0 Jan 23 04:25 /var/run/docker.sock`
- ✅ Working directory: `/github/workspace`
- ✅ All `GITHUB_*` env vars present
- ✅ Mounts: `/github/workspace`, `/github/home`, `/github/workflow`, `/github/file_commands`, `/github/runner_temp`

### Job-level `container:` with custom volumes:
- ✅ Docker socket present: `srw-rw---- 1 root 118 0 Jan 23 04:25 /var/run/docker.sock`
- ✅ Custom volumes mounted successfully
- ✅ All `GITHUB_*` env vars present
- ✅ Additional mounts: `/__e`, `/__t`, `/__w` (GHA runner tools)

## Conclusion

While the `uses: docker://` pattern is powerful and convenient for many use cases, our project's requirements (cache volumes, custom mounts, Docker-in-Docker) make the explicit `docker run` approach the better choice. The research confirms that both approaches have access to the Docker socket, which was the primary unknown.

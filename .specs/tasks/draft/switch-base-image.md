---
title: Switch base image to devcontainers/base
---

## Initial User Prompt

### Context

Current repo uses devctonainer/universal as base image, which is too big to properly work with our pipelines. 

### Requirements

- Switch this repo to  use mcr.microsoft.com/devcontainers/base as basis
- Together with mise, also install nix and https://github.com/jetify-com/devbox
- then use mise or nix to install version manageres like nvm (Need research which one is better as part of this plan generation)
- then pass it to Dockerfile.base -> Dockerfile.agents -> Dockerfile, same way as with universal. Add packages if there will be some need. 
- Update github workflow
- update Readme
- Use .devcontainer/Dockerfile as reference, we currently use this for our other projects. Install clis/packages that are mentioned there, but missing in devcontainer/base, for example gh cli.

## Plan

### Research Findings

#### Base Image

`mcr.microsoft.com/devcontainers/base` is the minimal counterpart to `devcontainers/universal`. It is maintained under the same `devcontainers/images` repo (https://github.com/devcontainers/images, tree `src/base-ubuntu`, `src/base-debian`, `src/base-alpine`) with the same proactive security patching and `cgmanifest.json` audit trail as the universal image, but it ships **no language runtimes** and only a thin layer of shell/dev utilities (`git`, `zsh`, Oh My Zsh!) on top of `buildpack-deps`. The default non-root user is **`vscode`** (UID/GID 1000) with passwordless `sudo` — this differs from `universal:6-noble` which ships `codespace`.

Variants considered (verify the live tag set at build time via `docker buildx imagetools inspect mcr.microsoft.com/devcontainers/base:ubuntu --raw` and the upstream tag list at `https://mcr.microsoft.com/v2/devcontainers/base/tags/list`):

| Tag family | Root OS | Notes |
|------------|---------|-------|
| `base:ubuntu` | Current Ubuntu LTS (currently noble per upstream README) | Floating "current LTS" alias. |
| `base:ubuntu-24.04` / `base:noble` | Ubuntu 24.04 LTS | Explicit LTS pin; rebuilt by Microsoft for CVE patches. |
| `base:ubuntu-26.04` / `base:resolute` | Ubuntu 26.04 | Newer; available per upstream tree (`src/base-ubuntu` lists `resolute`). Verify GA status. |
| `base:debian` / `base:bookworm` / `base:trixie` | Debian 12 / 13 | Smaller footprint than Ubuntu; trixie tracks Debian 13. |
| `base:alpine` | Alpine | Smallest, but musl-libc breaks many prebuilt binaries (Node prebuilt, mise's Rust release artifacts compile but Nix on Alpine is poorly supported). Not suitable here. |

**Decision: `mcr.microsoft.com/devcontainers/base:ubuntu-24.04`** as the base. Rationale: (1) Ubuntu noble matches what `universal:6-noble` we currently use, which keeps glibc/locale/apt-source compatibility for every script and CLI already validated against that platform; (2) Debian would also work but the migration delta is larger (different apt sources for `gh`, different Homebrew prerequisites); (3) Alpine is rejected outright — `nix` and `devbox` are first-class on glibc-Linux, and Alpine's musl produces friction we do not need; (4) explicit `ubuntu-24.04` (vs the floating `:ubuntu` alias) keeps the OS root explicit in the Dockerfile and is forward-compatible if Microsoft promotes `:ubuntu` to point at 26.04.

**Pin strategy: floating LTS tag (`ubuntu-24.04`), NOT an immutable `sha256:` digest** — same trade-off as the prior task's plan. Microsoft rebuilds the `base:*` tags on a regular cadence for CVE fixes; pinning a digest freezes us on a known-vulnerable image. Reproducibility for layers we own is recovered downstream:

1. The `build-base` CI job records the resolved upstream digest (`docker buildx imagetools inspect mcr.microsoft.com/devcontainers/base:ubuntu-24.04 --format '{{json .Manifest.Digest}}'`) as an OCI annotation on our published `:base`.
2. `Dockerfile.agents` and the final `Dockerfile` digest-pin our **own** layers (`ghcr.io/neolabhq/sandbox:base@sha256:<digest>` etc.).
3. Per-run SHA-suffixed tags (`:base-<sha>`, `:agents-<sha>`, `:latest-<sha>`) are published for instant rollback.

**Size comparison (order-of-magnitude only; confirm at build time via `docker image ls`):** `base:ubuntu-24.04` is roughly an order of magnitude smaller compressed than `universal:6-noble` because the universal image bundles Node, Python, Go, Java, Ruby, PHP, .NET, Conda plus their managers (~1-2 GB of runtimes). After we re-add the four languages we actually need via mise/nix on top of `base`, the resulting image is still expected to be materially smaller than universal — the user's stated motivation for this migration. Record the actual numbers in the workflow build summary (Step 5) so the README's "Image variants" section quotes verified sizes, not estimates.

```dockerfile
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04
```

No `@sha256:` suffix on this `FROM` line, by design.

#### Version Managers (the mise + nix + devbox stack)

The draft requirement explicitly asks for **all three** of `mise`, `nix`, and `devbox` to coexist, plus a recommendation for whether `mise` or `nix/devbox` should own language version managers like `nvm`. Each tool has a distinct role; they do not duplicate each other when used as recommended below.

**Role of each tool:**

- **`mise`** (https://mise.jdx.dev, https://github.com/jdx/mise) — single Rust binary, asdf-compatible meta version manager for *language runtimes*. First-class for Node, Python, Go, Java, Ruby, Deno, Bun. Ships shims-on-PATH mode (`/usr/local/share/mise/shims`) which works in non-interactive shells (Docker `RUN`, `docker exec`, CI) without requiring `eval "$(mise activate ...)"`. The upstream Docker cookbook (https://mise.jdx.dev/mise-cookbook/docker.html) recommends exactly this pattern. `mise install --system` puts tools under `/usr/local/share/mise/installs` so every user shares the same managed runtimes.

- **`nix`** (https://nixos.org) — fully-reproducible package manager for system-level / non-language tools (CLIs, libraries, headers). Single-user mode is the recommended install in Docker because containers have no systemd to host the daemon (`sh <(curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install) --no-daemon`, per https://nix.dev/manual/nix/stable/installation/single-user). Single-user install lives under `/nix/` with profile entry `~/.nix-profile/etc/profile.d/nix.sh`; we source this from `/etc/profile.d/nix.sh` so non-login shells pick it up.

- **`devbox`** (https://github.com/jetify-com/devbox) — Jetify's per-project Nix wrapper. It is **not a parallel package manager**; it consumes the same `/nix/store` that `nix` provides, but exposes a per-project `devbox.json` + `devbox.lock` (commit hash of nixpkgs) so each repo can declare its own ephemeral toolchain without forcing every dev to write Nix. Install: `curl -fsSL https://get.jetify.com/devbox | bash -s -- -f` (the `-f` flag skips the interactive prompt that otherwise hangs in Docker, per upstream issue #1594 and #2369). Devbox detects an existing nix install and reuses it.

**PATH ordering inside the image** (left-most wins):

```
/usr/local/share/mise/shims                # language runtimes (node, python, go, java, ...)
$HOME/.nix-profile/bin                     # nix-installed user CLIs
/nix/var/nix/profiles/default/bin          # nix-installed system CLIs
/usr/local/bin:/usr/bin:/bin               # apt-installed tools (gh, jq, build-essential, ...)
$HOME/.local/bin                           # claude code, opencode, user pip --user installs
/home/linuxbrew/.linuxbrew/bin             # Homebrew (optional fallback)
```

Rationale for ordering: language runtimes resolve through `mise` first (single source of truth for `node`/`python`/`go`/`java`). System CLIs prefer `nix` (reproducible) over `apt` (mutable). `apt` stays on PATH so anything we deliberately keep on the OS layer (e.g., `gh`, `git` — see top-up list below) still resolves. `~/.local/bin` is last for user-installed CLIs that should not shadow `nix` versions.

**Non-interactive shell behavior.** All three of these tools normally rely on shell rc-file activation (`eval "$(mise activate)"`, `. ~/.nix-profile/etc/profile.d/nix.sh`, `eval "$(devbox global shellenv)"`). In Docker `RUN`, `docker exec`, and CI runners the shell is non-interactive and does not source `.bashrc`/`.zshrc`. We therefore configure each tool through `/etc/profile.d/*.sh` fragments AND through baked-in `ENV PATH=...` directives in the Dockerfile, so the bare invocation (e.g., `docker run --rm <image> node --version`) works without `bash -lc`.

**Languages required: which manager owns `nvm`-style version pinning?**

The draft asks: "use mise or nix to install version managers like nvm (Need research which one is better as part of this plan generation)." Researched comparison:

| Property | `mise` for runtimes | `nix` (or `devbox`) for runtimes |
|----------|---------------------|----------------------------------|
| Footprint per language version | small (single tarball per version) | larger (full closure under `/nix/store`) |
| Switching versions at runtime | instant (`mise use node@22`) | requires nix-shell or devbox shell reload |
| Cross-language coverage | first-class for Node/Python/Go/Java/Ruby | needs nixpkgs attr per language |
| Reproducibility | tag-pinned via `mise.toml` (still fetches tarballs from upstream — not bit-for-bit) | bit-for-bit via `devbox.lock` (nixpkgs commit) |
| Familiarity for app devs | asdf-compatible, ergonomic, one-line CLI | steep learning curve |
| Fits the "replace nvm/pyenv/sdkman" mental model the draft asks about | Yes | No (different paradigm) |

**Decision: `mise` owns the four required language runtimes (Node, Python, Go, Java).** Rationale: (a) `mise` is purpose-built to replace `nvm`/`pyenv`/`goenv`/`sdkman` with a single CLI and a single `mise.toml`, which is exactly the workflow the draft asks for; (b) shim resolution works in non-interactive Docker shells without `mise activate`; (c) version switching is a one-liner that any dev who knows `nvm`/`pyenv` already understands; (d) the user's existing `.devcontainer/Dockerfile` already follows this model (Node from a `:24-bullseye` base, Go from a tarball under `/usr/local/go`) — `mise` is the natural consolidation. **`nix` owns reproducible system CLIs / dev libraries** that are awkward to install via apt and that we explicitly want pinned to a `devbox.lock` (e.g., `pre-commit`, `lefthook`, `tree-sitter`, project-specific linters). **`devbox` is exposed for per-project use** (`devbox.json` checked into a downstream repo) but **no image-wide `devbox.json` is shipped** — Devbox composes with the nix install we already ship, so projects can opt in without re-installing nix.

Anti-pattern explicitly rejected: installing `nvm`/`pyenv`/`sdkman` inside the new image. That would re-introduce the universal-image style fragmentation across three managers when one (`mise`) already covers them all and is what the draft asks us to standardize on.

#### Languages

Researched coverage matrix (verify at build time via `docker run --rm <image> bash -lc 'mise current && node --version && python3 --version && go version && java --version'`):

| Language | Manager owner | Pin syntax in `mise.toml` | Hedged default |
|----------|---------------|--------------------------|----------------|
| Node.js | `mise` | `node = "lts"` | current Node LTS |
| Python | `mise` | `python = "latest"` | current stable Python 3 (≥ 3.12) |
| Go | `mise` | `go = "latest"` | current stable Go |
| Java | `mise` | `java = "temurin-lts"` | current Eclipse Temurin LTS |

Resolution is deferred to `mise install` at build time so security/patch rolls flow in automatically (mirrors the floating-tag pin strategy for the base image). Exact resolved versions are recorded by the Step 7 verification commands and surfaced in the CI build summary — they are not pinned in the Dockerfile. Per `/workspaces/sandbox/.claude/rules/research-version-claims.md`, do NOT write specific version numbers into the Dockerfile or README as "verified facts."

For project-specific overrides, a downstream repo drops a `mise.toml` at its root (or a `devbox.json` for nix-managed tooling); both are detected automatically.

#### Missing tooling vs `devcontainers/base`

Derived by reading `/workspaces/sandbox/.devcontainer/Dockerfile` lines 7-103 (the current legacy image's stage 1+2 installs) and cross-referencing against the `base-ubuntu` README and Dockerfile (which install only `git`, `zsh`, Oh My Zsh!, and `tzdata` reinstall — see https://github.com/devcontainers/images/blob/main/src/base-ubuntu/.devcontainer/Dockerfile).

**Top-up list — must be added in `Dockerfile.base` because `base:ubuntu-24.04` does not ship them:**

apt packages (lines 7-58 of current Dockerfile): `apt-utils`, `bash-completion`, `openssh-client`, `gnupg2`, `dirmngr`, `iproute2`, `procps`, `lsof`, `htop`, `net-tools`, `psmisc`, `curl`, `tree`, `wget`, `rsync`, `ca-certificates`, `unzip`, `bzip2`, `xz-utils`, `zip`, `nano`, `vim-tiny`, `less`, `jq`, `lsb-release`, `apt-transport-https`, `dialog`, `libc6`, `libgcc1`, `libkrb5-3`, `libgssapi-krb5-2`, `libicu[0-9][0-9]`, `liblttng-ust[0-9]`, `libstdc++6`, `zlib1g`, `locales`, `sudo`, `ncdu`, `man-db`, `strace`, `manpages`, `manpages-dev`, `init-system-helpers`, `build-essential`, `file`, `retry`, `python3`, `python3-pip` (the last two are only kept as a bootstrap for `pip install dvc yq`; the real Python that devs use comes from `mise`).

Standalone installs (lines 64-103 of current Dockerfile): **`gh` CLI** (explicit example from the draft — its apt repo + key install on lines 64-73), **Homebrew (Linuxbrew)** (line 99), and the npm globals `typescript-language-server typescript rust-just bun` (line 103) — the npm globals move to `Dockerfile.agents` because they require the mise-managed Node to exist.

NOT re-installed at apt level (because `mise` now owns them): `nvm`, `nodejs`, `python3` (as runtime), `golang-go`, `default-jdk` — all four come from `mise install` instead.

New additions (not in the current `.devcontainer/Dockerfile` but required by this task): `mise`, `nix` (single-user), `devbox`.

#### AI Coding Agents

Identical to the prior task's plan — no provider has changed installer commands. Installer commands carried over verbatim:

- **Claude Code** — `curl -fsSL https://claude.ai/install.sh | bash`. Installs to `~/.local/bin/claude`.
- **OpenCode** — `curl -fsSL https://opencode.ai/install | bash`. Installs as `opencode`.
- **Gemini CLI** — `npm install -g @google/gemini-cli` (requires Node ≥ 20 — guaranteed by `mise` pinning `node@lts`).
- **Codex (OpenAI)** — `npm install -g @openai/codex`.

All four install cleanly under the `vscode` user's home; no root-level changes beyond ensuring `PATH` includes `~/.local/bin` and the npm global prefix.

#### MCP Servers

- **Context7** — registered at runtime via `claude mcp add --scope user --transport http context7 https://mcp.context7.com/mcp` (keep existing `install-mcps.sh` pattern; needs `CONTEXT7_API_KEY`).
- **Codemap** — Go binary built from `https://github.com/JordanCoin/codemap`. Built in `Dockerfile.agents` using the mise-managed Go.
- **Language servers** — `typescript-language-server` (npm), `pyright` (npm), `gopls` (`go install golang.org/x/tools/gopls@latest`), `jdtls` (Eclipse JDT tarball under `/opt/jdtls`). All installed in `Dockerfile.agents`.
- **`docker-mcp` CLI plugin** — migrated out of `.devcontainer/devcontainer.json`'s `bash-command` feature into `Dockerfile.agents` (same rationale as the prior plan: it's deterministic, doesn't need host state, and saves ~30-60s on every devcontainer start).

#### GitHub Container Registry Workflow

Same shape as the prior plan, three sequential jobs (`build-base` → `build-agents` → `build-final`), each pushing to `ghcr.io/neolabhq/sandbox` (lowercase org, GHCR rule). Differences vs the prior plan:

- The `build-base` job's matrix-of-base-image-digests now records `mcr.microsoft.com/devcontainers/base:ubuntu-24.04` rather than `universal:6-noble`.
- `cache-from`/`cache-to` scopes are split per Dockerfile (`scope=base`, `scope=agents`, `scope=final`) so a base-only change doesn't invalidate the agents-layer cache.
- Per-run rollback tags (`:base-<sha>`, `:agents-<sha>`, `:latest-<sha>`) are unchanged.

#### Claude Code Volume Mounting

Same as prior plan, BUT the target paths inside the image change from `/home/codespace/...` to `/home/vscode/...` because the new base ships `vscode` (UID 1000) instead of `codespace`. Recommended `docker run` mounts:

```bash
-v "$HOME/.claude:/home/vscode/.claude" \
-v "$HOME/.claude.json:/home/vscode/.claude.json" \
-e CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN"
```

Ephemeral / CI usage drops the two volume mounts and relies on `CLAUDE_CODE_OAUTH_TOKEN` alone — Claude Code skips onboarding and discards state on container exit.

---

### Implementation Steps

#### Step 1: Create `Dockerfile.base`

Create `/workspaces/sandbox/Dockerfile.base`.

- `FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04` — no digest pin (see Base Image rationale).
- Per `/workspaces/sandbox/.claude/rules/dockerfile-curl-pipe-pipefail.md`, declare `SHELL ["/bin/bash", "-o", "pipefail", "-c"]` BEFORE any `curl ... | bash` line so pipeline failures abort the layer instead of silently producing an empty install. Apply this once near the top of every Dockerfile in the chain.
- `USER root` for setup, drop back to `vscode` at the end.
- Install the apt top-up list derived from `.devcontainer/Dockerfile` lines 7-58:
  ```dockerfile
  USER root
  SHELL ["/bin/bash", "-o", "pipefail", "-c"]
  RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        apt-utils bash-completion openssh-client gnupg2 dirmngr iproute2 procps lsof htop \
        net-tools psmisc curl tree wget rsync ca-certificates unzip bzip2 xz-utils zip nano \
        vim-tiny less jq lsb-release apt-transport-https dialog libc6 libgcc-s1 libkrb5-3 \
        libgssapi-krb5-2 'libicu[0-9][0-9]' 'liblttng-ust[0-9]' libstdc++6 zlib1g locales sudo \
        ncdu man-db strace manpages manpages-dev init-system-helpers build-essential file retry \
        python3 python3-pip \
   && apt-get -y upgrade --no-install-recommends \
   && apt-get autoremove -y && apt-get clean && rm -rf /var/lib/apt/lists/*
  ```
  (Note: `libgcc1` was renamed to `libgcc-s1` on noble; this is the only deviation from a verbatim copy of the legacy package list.)
- Install **`gh` CLI** (verbatim from current Dockerfile lines 64-73, except `sudo` is dropped because we are already root):
  ```dockerfile
  RUN mkdir -p -m 755 /etc/apt/keyrings \
   && out=$(mktemp) && wget -nv -O"$out" https://cli.github.com/packages/githubcli-archive-keyring.gpg \
   && cat "$out" > /etc/apt/keyrings/githubcli-archive-keyring.gpg \
   && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
   && mkdir -p -m 755 /etc/apt/sources.list.d \
   && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
   && apt-get update && apt-get install -y --no-install-recommends gh \
   && rm -rf /var/lib/apt/lists/*
  ```
- Install **`mise`** system-wide (https://mise.jdx.dev/mise-cookbook/docker.html):
  ```dockerfile
  ENV MISE_INSTALL_PATH=/usr/local/bin/mise
  ENV MISE_DATA_DIR=/usr/local/share/mise
  ENV MISE_CONFIG_DIR=/etc/mise
  ENV MISE_CACHE_DIR=/var/cache/mise
  RUN curl -fsSL https://mise.run | sh \
   && mkdir -p "$MISE_DATA_DIR" "$MISE_CONFIG_DIR" "$MISE_CACHE_DIR" \
   && chown -R vscode:vscode "$MISE_DATA_DIR" "$MISE_CONFIG_DIR" "$MISE_CACHE_DIR"
  # Shims on PATH for non-interactive shells (Docker RUN, docker exec, CI).
  RUN printf '%s\n' \
        'export MISE_DATA_DIR=/usr/local/share/mise' \
        'export PATH=/usr/local/share/mise/shims:$PATH' \
        > /etc/profile.d/mise.sh \
   && chmod 0644 /etc/profile.d/mise.sh
  ENV PATH=/usr/local/share/mise/shims:${PATH}
  ```
- Install **`nix`** in single-user mode (per https://nix.dev/manual/nix/stable/installation/single-user — Docker has no systemd, so daemon mode is rejected):
  ```dockerfile
  # nix wants to manage /nix itself; create it and chown to vscode so single-user install works.
  RUN mkdir -m 0755 /nix && chown vscode:vscode /nix
  USER vscode
  RUN curl --proto '=https' --tlsv1.2 -sSf -L https://nixos.org/nix/install -o /tmp/nix-install.sh \
   && sh /tmp/nix-install.sh --no-daemon \
   && rm /tmp/nix-install.sh
  USER root
  # Source nix profile from /etc/profile.d so non-login shells pick it up too.
  RUN printf '%s\n' \
        'if [ -e /home/vscode/.nix-profile/etc/profile.d/nix.sh ]; then' \
        '  . /home/vscode/.nix-profile/etc/profile.d/nix.sh' \
        'fi' \
        > /etc/profile.d/nix.sh \
   && chmod 0644 /etc/profile.d/nix.sh
  ENV PATH=/home/vscode/.nix-profile/bin:${PATH}
  ```
- Install **`devbox`** (Jetify) — needs the `-f` flag to skip the interactive prompt that hangs in Docker (per upstream issue jetify-com/devbox#1594 and #2369):
  ```dockerfile
  RUN curl -fsSL https://get.jetify.com/devbox | bash -s -- -f
  # devbox is installed to /usr/local/bin/devbox by the installer when run as root.
  # devbox reuses the nix install above (it does NOT bundle its own nix when one is present).
  ```
- Install **Homebrew (Linuxbrew)** as the `vscode` user (preserves the existing project pattern from `.devcontainer/Dockerfile` line 99):
  ```dockerfile
  USER vscode
  RUN NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  USER root
  RUN printf '%s\n' \
        'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' \
        > /etc/profile.d/linuxbrew.sh \
   && chmod 0644 /etc/profile.d/linuxbrew.sh
  ENV PATH=/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:${PATH}
  ```
- Set mise global defaults for the four required languages, hedged per `/workspaces/sandbox/.claude/rules/research-version-claims.md`:
  ```dockerfile
  USER vscode
  # `lts`/`latest`/`temurin-lts` resolve at build time; exact versions land in the
  # build summary via the Step 7 verification commands, not in the Dockerfile.
  RUN mise use --global node@lts python@latest go@latest java@temurin-lts \
   && mise install \
   && mise reshim
  ```
- Install pip-level helpers used by existing scripts (`dvc`, `yq`) into the system Python with `--break-system-packages` (Ubuntu 24.04 PEP 668 enforces this):
  ```dockerfile
  USER root
  RUN pip3 install --break-system-packages dvc yq
  ```
- **Non-root user: `vscode`** (UID/GID 1000, shipped by `base:ubuntu-24.04`). We do NOT create a `node` or `codespace` user. Existing script references to `/home/node/...` are rewritten to `$HOME/...` in Step 4 (preferred — user-agnostic) or to `/home/vscode/...` where `$HOME` is unsafe.

Output image tag: `ghcr.io/neolabhq/sandbox:base`.

#### Step 2: Create `Dockerfile.agents`

Create `/workspaces/sandbox/Dockerfile.agents`.

- `ARG BASE_IMAGE=ghcr.io/neolabhq/sandbox:base`
- `FROM ${BASE_IMAGE}` — CI pins this to `:base@sha256:<digest>` resolved by the `build-base` job.
- `SHELL ["/bin/bash", "-o", "pipefail", "-c"]` per the curl-pipe rule.
- `USER vscode`.
- Install **Claude Code**: `curl -fsSL https://claude.ai/install.sh | bash`. Ensure `PATH` includes `/home/vscode/.local/bin`.
- Install **OpenCode**: `curl -fsSL https://opencode.ai/install | bash`.
- Install **Gemini CLI**: `npm install -g @google/gemini-cli` (`mise`-managed Node from Step 1; npm global prefix is the user's home so no `sudo`).
- Install **Codex CLI**: `npm install -g @openai/codex`.
- Install **TypeScript LSP and helpful global tools**: `npm install -g typescript-language-server typescript rust-just bun` (preserves the behavior of current `.devcontainer/Dockerfile` line 103).
- Install **codemap** using the mise-managed Go:
  ```dockerfile
  USER root
  RUN git clone --depth 1 https://github.com/JordanCoin/codemap.git /tmp/codemap \
   && cd /tmp/codemap && /usr/local/share/mise/shims/go build -o /usr/local/bin/codemap . \
   && rm -rf /tmp/codemap
  USER vscode
  ```
- Install **gopls**: `go install golang.org/x/tools/gopls@latest`.
- Install **pyright**: `npm install -g pyright`.
- Install **jdtls**: download the current milestone tarball from `https://download.eclipse.org/jdtls/milestones/` (no specific version pinned — hedged per the version-claims rule; the Step 7 verification command records what was actually downloaded), extract to `/opt/jdtls`, symlink launcher to `/usr/local/bin/jdtls`.
- Install **`docker-mcp` CLI plugin** (migrated out of `.devcontainer/devcontainer.json` bash-command feature):
  ```dockerfile
  USER vscode
  RUN git clone --depth 1 https://github.com/docker/mcp-gateway.git /tmp/mcp-gateway \
   && cd /tmp/mcp-gateway \
   && mkdir -p /home/vscode/.docker/cli-plugins \
   && HOME=/home/vscode DOCKER_MCP_CLI_PLUGIN_DST=/home/vscode/.docker/cli-plugins/docker-mcp make docker-mcp \
   && rm -rf /tmp/mcp-gateway
  ```
  Runtime Docker CLI comes from the devcontainer's `docker-outside-of-docker` feature.

Output image tag: `ghcr.io/neolabhq/sandbox:agents`.

#### Step 3: Create final `Dockerfile`

Create `/workspaces/sandbox/Dockerfile`.

- `ARG AGENTS_IMAGE=ghcr.io/neolabhq/sandbox:agents`
- `FROM ${AGENTS_IMAGE}` — digest-pinned by the `build-agents` CI job.
- `SHELL ["/bin/bash", "-o", "pipefail", "-c"]`.
- `USER root`
- `COPY configure-claude.sh statusline.sh install-mcps.sh /opt/devcontainer/`
- `RUN chmod +x /opt/devcontainer/*.sh`
- `ENV DOCKER_MCP_IN_CONTAINER=1`
- `USER vscode`
- **Verify codemap and language MCP servers are present** (inherited from agents image): `RUN command -v codemap && command -v gopls && command -v pyright && command -v jdtls` — fails fast if the agents image ever drops one.
- `RUN /opt/devcontainer/configure-claude.sh` — bootstraps `~/.claude/settings.json`, statusline, and Claude plugins.
- Do NOT run `install-mcps.sh` at build time — it needs `CONTEXT7_API_KEY` only available at runtime; keep it as `postCreateCommand`.
- `WORKDIR /workspaces`
- `CMD ["sleep","infinity"]`

Output image tag: `ghcr.io/neolabhq/sandbox:latest`.

#### Step 4: Move scripts from `.devcontainer/` to repo root and migrate `devcontainer.json`

**Move scripts preserving permissions** per `/workspaces/sandbox/.claude/rules/preserve-permissions-on-move.md`. Current modes are `664 664 775` for `configure-claude.sh / install-mcps.sh / statusline.sh` (verified via `stat -c '%a %n'`). Use `git mv` so mode bits AND rename history are preserved; the three scripts are currently untracked per `git status`, so use `mv` (untracked files have no index entry yet, but a plain `mv` still preserves inode metadata) followed by `git add` at the new location:

```bash
# Untracked files — plain mv preserves mode/timestamps; do NOT read+Write.
mv .devcontainer/configure-claude.sh configure-claude.sh
mv .devcontainer/install-mcps.sh    install-mcps.sh
mv .devcontainer/statusline.sh      statusline.sh

# Targeted text rewrite — only /home/node/ → $HOME/ changes.
sed -i 's|/home/node/|$HOME/|g' configure-claude.sh install-mcps.sh statusline.sh

# Verify modes survived unchanged.
stat -c '%a %n' configure-claude.sh install-mcps.sh statusline.sh   # expect: 664 664 775
git diff -- configure-claude.sh install-mcps.sh statusline.sh        # only $HOME/ change
git add configure-claude.sh install-mcps.sh statusline.sh
```

**Why `$HOME/` over `/home/vscode/`**: the previous task chose `$HOME/`; we keep that convention so a future user-rename does not require another sweep. The scripts are bash, so `$HOME/` resolves correctly even in non-interactive shells.

**Replace `.devcontainer/Dockerfile`** with a thin wrapper:
```dockerfile
FROM ghcr.io/neolabhq/sandbox:latest
```
Keeping the file (vs deleting it) preserves the build-context affordance for devcontainer features that compose on top.

**Update `.devcontainer/devcontainer.json`** — per-entry decision table for **every** property currently in the file:

| `devcontainer.json` entry | Current value | Decision | Rationale |
|---------------------------|---------------|----------|-----------|
| `name` | `"NeoLabHQ Sandbox (Ubuntu 24.04)"` | **Preserve** | Already reflects target OS; no change needed. |
| `build.dockerfile` | `"Dockerfile"` | **Replace with `"image": "ghcr.io/neolabhq/sandbox:latest"`** | Devcontainer now consumes the published image rather than rebuilding locally. |
| `features["ghcr.io/devcontainers/features/docker-outside-of-docker:1"]` | `{}` | **Preserve in devcontainer.json (do NOT bake)** | Requires host-level socket mount and GID mapping that only the devcontainer CLI / VS Code can wire up. |
| `features["ghcr.io/devcontainers-extra/features/bash-command:1"]` (docker-mcp install) | bash command cloning `docker/mcp-gateway` and installing `docker-mcp` plugin to `/home/node/.docker/cli-plugins/` | **Remove — baked into `Dockerfile.agents`** | Deterministic build step; no runtime/host dependency. Faster devcontainer start, available for plain `docker run` users, install path updated to `/home/vscode/.docker/cli-plugins/`. |
| `customizations.vscode.settings.terminal.integrated.defaultProfile.linux` | `"zsh"` | **Preserve** | VS Code UX setting; no image equivalent. |
| `customizations.vscode.extensions` | 6 extensions | **Preserve** | VS Code-specific. |
| `forwardPorts` | `[3000, 8080]` | **Preserve** | Devcontainer-spec only. |
| `portsAttributes."3000"` | `{ "label": "Dev Server", "onAutoForward": "notify" }` | **Preserve** | Devcontainer-spec only. |
| `containerEnv.NODE_ENV` | `"development"` | **Preserve in devcontainer.json (do NOT bake)** | Dev-environment default; would be wrong baked into a generic image used in CI. |
| `containerEnv.COLORTERM` | `"truecolor"` | **Preserve** | Dev-environment terminal hint. |
| `remoteEnv.ANTHROPIC_API_KEY` | `${localEnv:ANTHROPIC_API_KEY}` | **Preserve** | Host secret passthrough. |
| `remoteEnv.CLAUDE_CODE_OAUTH_TOKEN` | `${localEnv:CLAUDE_CODE_OAUTH_TOKEN}` | **Preserve** | Host secret passthrough. |
| `remoteEnv.CONTEXT7_API_KEY` | `${localEnv:CONTEXT7_API_KEY}` | **Preserve** | Host secret passthrough. |
| `postCreateCommand.install-mcps` | `/opt/devcontainer/install-mcps.sh` | **Preserve** — path is stable inside the new image (COPYed by final `Dockerfile`) | Needs runtime secrets; cannot be baked. |
| `remoteUser` | `"node"` | **Update to `"vscode"`** | New base image ships `vscode` (UID 1000); literal `node` user does not exist. |

Net edits to `.devcontainer/devcontainer.json`:
1. Replace `"build": { "dockerfile": "Dockerfile" }` with `"image": "ghcr.io/neolabhq/sandbox:latest"`.
2. Remove the `ghcr.io/devcontainers-extra/features/bash-command:1` feature entry entirely.
3. Update `"remoteUser": "node"` → `"remoteUser": "vscode"`.
4. Everything else verbatim.

#### Step 5: Create `.github/workflows/docker-publish.yml`

Triggers: `push` to `master`, `workflow_dispatch`, tag pushes (`v*`).

Permissions: `contents: read`, `packages: write`, `security-events: write` (for SARIF upload).

A separate `lint` job runs first and is a `needs:` dependency of all three build jobs. This enforces `/workspaces/sandbox/.claude/rules/dockerfile-curl-pipe-pipefail.md` at CI time by running hadolint with `DL4006` enabled across every `Dockerfile*` in the repo. Placing the linter in its own job (rather than a per-build pre-step) lints all three Dockerfiles in one place, fails fast before any image is built, and keeps the build jobs focused on build/scan/push.

0. **`lint`** — `hadolint/hadolint-action@v3` runs against `Dockerfile.base`, `Dockerfile.agents`, `Dockerfile`, and `.devcontainer/Dockerfile`. Configure with `failure-threshold: warning` and an inline `--require-label DL4006=error` (or an equivalent `.hadolint.yaml` enabling rule `DL4006`) so any `curl ... | bash` line without a preceding `SHELL ["/bin/bash", "-o", "pipefail", "-c"]` is rejected. Cross-reference: `/workspaces/sandbox/.claude/rules/dockerfile-curl-pipe-pipefail.md`. Example step:
   ```yaml
   - name: Lint Dockerfiles (enforce DL4006 / curl|bash pipefail)
     uses: hadolint/hadolint-action@v3
     with:
       dockerfile: Dockerfile.base
       failure-threshold: warning
       override-error: DL4006
   ```
   Repeat for `Dockerfile.agents`, `Dockerfile`, and `.devcontainer/Dockerfile` (or use a single `recursive: true` invocation if the action version in use supports it — verify against the action's release notes at build time).

Three sequential build jobs (each declares `needs: lint` so a hadolint failure short-circuits the whole pipeline):

1. **`build-base`** — `needs: lint`. `docker/build-push-action@v6` builds `Dockerfile.base`, scans with Trivy, then pushes `ghcr.io/neolabhq/sandbox:base` AND `:base-<sha>`. Records the resolved `mcr.microsoft.com/devcontainers/base:ubuntu-24.04` digest as an OCI annotation and into the build summary.
2. **`build-agents`** — `needs: [lint, build-base]`. `build-args: BASE_IMAGE=ghcr.io/neolabhq/sandbox:base@sha256:<digest>` from job 1's output. Pushes `:agents` and `:agents-<sha>`.
3. **`build-final`** — `needs: [lint, build-agents]`. `build-args: AGENTS_IMAGE=ghcr.io/neolabhq/sandbox:agents@sha256:<digest>`. Pushes `:latest` and `:latest-<sha>`.

Each job:
- `actions/checkout@v4`
- `docker/setup-qemu-action@v3`, `docker/setup-buildx-action@v3`
- `docker/login-action@v3` (registry `ghcr.io`, password `${{ secrets.GITHUB_TOKEN }}`)
- `docker/metadata-action@v5` for tag generation
- **Build → scan → push**: first `build-push-action` invocation with `push: false, load: true` for single-arch local scan; `aquasecurity/trivy-action` (latest stable, pinned by SHA at PR-merge time per the curl-pipe-and-version-pin discipline) with `severity: CRITICAL,HIGH, exit-code: 1, ignore-unfixed: true`; SARIF upload via `github/codeql-action/upload-sarif@v3`; SBOM via `anchore/sbom-action@v0`; final `build-push-action` with `push: true, platforms: linux/amd64,linux/arm64, cache-from/to: type=gha,scope=<base|agents|final>`.

Note: org name in GHCR must be lowercase (`neolabhq/sandbox`).

Optional but recommended: a separate scheduled workflow (`cron`) re-scans the latest `:base`, `:agents`, `:latest` weekly.

##### Rollback plan

Same shape as the prior plan, adapted for the new base:

- Every workflow run pushes immutable `:base-<sha>`, `:agents-<sha>`, `:latest-<sha>`. To restore service: `docker buildx imagetools create -t ghcr.io/neolabhq/sandbox:latest ghcr.io/neolabhq/sandbox:latest-<previous-good-sha>` — atomic at the registry, no rebuild.
- Revert digest pins in `Dockerfile.agents` / final `Dockerfile` / `.devcontainer/Dockerfile` to a previous good `:base@sha256:<digest>` / `:agents@sha256:<digest>` and re-run.
- For an upstream Microsoft regression (the floating `base:ubuntu-24.04` tag rebuild went bad): emergency-pin `Dockerfile.base` to `mcr.microsoft.com/devcontainers/base:ubuntu-24.04@sha256:<last-good>` recorded in the `build-base` OCI annotation, then revert to the floating tag once upstream stabilizes.
- Invalidate poisoned GHA cache scopes via `gh actions-cache delete` so bad layers are not silently reused.

#### Step 6: Update `README.md`

Replace the current README with comprehensive docs. Same outline as the prior plan, with paths updated to `/home/vscode/...` and a new section explicitly documenting the mise + nix + devbox stack:

1. **Overview** — what the image is, what's preinstalled (mise-managed Node/Python/Go/Java + nix + devbox + AI agents + MCP plugins + LSPs).
2. **Image variants & tags** — `:base`, `:agents`, `:latest`, plus immutable `:<variant>-<sha>` tags.
3. **Quick start with Docker (persistent setup)** — `~/.claude` and `~/.claude.json` mapped to `/home/vscode/...`.
4. **Quick start without persistent Claude state (ephemeral / CI)** — `CLAUDE_CODE_OAUTH_TOKEN` only.
5. **Volume mapping for projects** — workspace mount + Claude mounts + optional SSH/git config.
6. **Mounting multiple project directories** — multi-`-v` pattern under `/workspaces`.
7. **Passing `CLAUDE_CODE_OAUTH_TOKEN`** — `claude setup-token` on host; mention `ANTHROPIC_API_KEY` and `CONTEXT7_API_KEY`.
8. **Language version manager stack (mise + nix + devbox)** — NEW section explaining:
   - `mise` owns runtimes (Node/Python/Go/Java); override per project via `mise.toml`.
   - `nix` is single-user, source `/etc/profile.d/nix.sh` for non-login shells.
   - `devbox` is per-project — drop a `devbox.json` at a repo root to declare reproducible nix-managed tooling.
   - Quote runtime-verifiable commands for each:
     - `docker run --rm ghcr.io/neolabhq/sandbox:latest bash -lc 'mise --version && mise current && node --version && python3 --version && go version && java --version'`
     - `docker run --rm ghcr.io/neolabhq/sandbox:latest bash -lc 'nix --version && nix-env -q'`
     - `docker run --rm ghcr.io/neolabhq/sandbox:latest bash -lc 'devbox version'`
9. **Using as a devcontainer** — quick setup (`"image": "ghcr.io/neolabhq/sandbox:latest"` + `docker-outside-of-docker` feature + `"remoteUser": "vscode"`) and Docker-MCP setup variant.
10. **Tools included** — list languages (hedged per `/workspaces/sandbox/.claude/rules/research-version-claims.md`: "Node, Python, Go, Java — managed by `mise` at current-LTS / current-stable defaults; exact resolved versions are documented in the CI build summary"), version managers (`mise` + `nix` + `devbox`), agents (Claude Code, OpenCode, Gemini CLI, Codex), MCP servers (Context7, codemap, docker-mcp), LSPs (gopls, pyright, jdtls, typescript-language-server), plus Homebrew and `gh` CLI.
11. **Building locally** — `docker build -f Dockerfile.base -t sandbox:base .` chain.

##### Example: persistent Claude state (recommended for daily dev)

```bash
docker run -it --rm \
  -v "$PWD:/workspaces/$(basename "$PWD")" \
  -v "$HOME/.claude:/home/vscode/.claude" \
  -v "$HOME/.claude.json:/home/vscode/.claude.json" \
  -e CLAUDE_CODE_OAUTH_TOKEN \
  -e ANTHROPIC_API_KEY \
  -e CONTEXT7_API_KEY \
  -w "/workspaces/$(basename "$PWD")" \
  ghcr.io/neolabhq/sandbox:latest \
  bash
```

##### Example: ephemeral / single-shot (CI, throwaway sandboxes)

```bash
docker run -it --rm \
  -v "$PWD:/workspaces/$(basename "$PWD")" \
  -e CLAUDE_CODE_OAUTH_TOKEN \
  -e ANTHROPIC_API_KEY \
  -e CONTEXT7_API_KEY \
  -w "/workspaces/$(basename "$PWD")" \
  ghcr.io/neolabhq/sandbox:latest \
  bash
```

##### Example: multiple project directories in one container

Mount each project under a sibling path inside `/workspaces`:

```bash
docker run -it --rm \
  -v "$HOME/code/project-a:/workspaces/project-a" \
  -v "$HOME/code/project-b:/workspaces/project-b" \
  -v "$HOME/code/shared-lib:/workspaces/shared-lib" \
  -v "$HOME/.claude:/home/vscode/.claude" \
  -v "$HOME/.claude.json:/home/vscode/.claude.json" \
  -e CLAUDE_CODE_OAUTH_TOKEN \
  -e ANTHROPIC_API_KEY \
  -e CONTEXT7_API_KEY \
  -w "/workspaces" \
  ghcr.io/neolabhq/sandbox:latest \
  bash
```

The README will note: (1) keep each project in its own sub-directory under `/workspaces/` — agents and LSPs locate project roots by walking up to the nearest `.git`/`pyproject.toml`/`go.mod`/etc., so siblings stay isolated; (2) cross-project refactors work because all projects share one container PATH, `gh` auth, and Claude session; (3) for write isolation use `:ro` on the read-only mounts (e.g., a vendored monorepo dependency mounted as `-v "$HOME/code/shared-lib:/workspaces/shared-lib:ro"`).

##### Example: quick devcontainer setup

```jsonc
{
  "name": "NeoLabHQ Sandbox",
  "image": "ghcr.io/neolabhq/sandbox:latest",
  "features": {
    "ghcr.io/devcontainers/features/docker-outside-of-docker:1": {}
  },
  "remoteUser": "vscode",
  "remoteEnv": {
    "CLAUDE_CODE_OAUTH_TOKEN": "${localEnv:CLAUDE_CODE_OAUTH_TOKEN}",
    "ANTHROPIC_API_KEY": "${localEnv:ANTHROPIC_API_KEY}",
    "CONTEXT7_API_KEY": "${localEnv:CONTEXT7_API_KEY}"
  },
  "postCreateCommand": "/opt/devcontainer/install-mcps.sh"
}
```

##### Example: devcontainer with Docker MCP

```jsonc
{
  "name": "NeoLabHQ Sandbox (Docker MCP)",
  "image": "ghcr.io/neolabhq/sandbox:latest",
  "features": {
    "ghcr.io/devcontainers/features/docker-outside-of-docker:1": {}
  },
  "mounts": [
    "source=${localEnv:HOME}/.docker/mcp,target=/home/vscode/.docker/mcp,type=bind,consistency=cached"
  ],
  "remoteUser": "vscode",
  "remoteEnv": {
    "CLAUDE_CODE_OAUTH_TOKEN": "${localEnv:CLAUDE_CODE_OAUTH_TOKEN}",
    "DOCKER_MCP_CATALOG_DIR": "/home/vscode/.docker/mcp"
  },
  "postCreateCommand": "docker mcp gateway run --help >/dev/null && /opt/devcontainer/install-mcps.sh"
}
```

Outbound links:
- Docker MCP Catalog & Toolkit: https://docs.docker.com/ai/mcp-catalog-and-toolkit/
- `docker/mcp-gateway`: https://github.com/docker/mcp-gateway
- mise: https://mise.jdx.dev / https://mise.jdx.dev/mise-cookbook/docker.html
- nix (single-user): https://nix.dev/manual/nix/stable/installation/single-user
- devbox: https://github.com/jetify-com/devbox / https://www.jetify.com/devbox/docs/quickstart/

#### Step 7: Verify and iterate

Build all three images locally with `docker buildx build` to confirm the chain works. Then, against each image, run the runtime-verifiable commands below (each output line is what becomes the "as-of-build" anchor for the version-claims rule — no specific version is asserted in the Dockerfile, only here):

- **User identity**: `docker run --rm ghcr.io/neolabhq/sandbox:latest id` — expect `uid=1000(vscode)`.
- **mise + languages** (Node, Python, Go, Java):
  ```bash
  docker run --rm ghcr.io/neolabhq/sandbox:latest bash -lc \
    'mise --version && mise current && mise ls --global \
     && node --version && python3 --version && go version && java --version \
     && command -v node && command -v python3 && command -v go && command -v java'
  ```
  Expect every `command -v` to resolve under `/usr/local/share/mise/shims/`.
- **nix**: `docker run --rm ghcr.io/neolabhq/sandbox:latest bash -lc 'nix --version && nix-env --version'`.
- **devbox**: `docker run --rm ghcr.io/neolabhq/sandbox:latest bash -lc 'devbox version'`.
- **Top-up CLIs**: `docker run --rm ghcr.io/neolabhq/sandbox:latest bash -lc 'gh --version && jq --version && brew --version && git --version'`.
- **Agents (in `:agents` and `:latest`)**: `claude --version`, `opencode --version`, `gemini --version`, `codex --version`.
- **MCP / LSPs**: `codemap --help`, `gopls version`, `pyright --version`, `jdtls --help`, `typescript-language-server --version`, `docker mcp --help`.
- **Final-layer wiring**: confirm `/home/vscode/.claude/settings.json` is populated after `configure-claude.sh` ran; statusline runs.
- **Ephemeral / single-shot flow**: run without `~/.claude*` mounts, only `CLAUDE_CODE_OAUTH_TOKEN`, confirm `claude --version` works.
- **Upstream sanity check** (for the Research Findings tables): `docker run --rm mcr.microsoft.com/devcontainers/base:ubuntu-24.04 bash -lc 'cat /etc/os-release && id vscode && which git zsh && (which gh || echo no-gh) && (which node || echo no-node) && (which python3 || echo no-python)'`.
- **Devcontainer attach**: rebuild the devcontainer using `.devcontainer/devcontainer.json` and confirm VS Code attach works with `remoteUser: vscode`.

---

### Technical Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Base image variant | `mcr.microsoft.com/devcontainers/base:ubuntu-24.04` | Ubuntu noble matches the previous task's `universal:6-noble` so glibc/locale/apt-source compatibility carries over. Debian considered (smaller) but rejected because the migration delta on `gh` apt source + Homebrew prerequisites is larger. Alpine rejected because nix/devbox are poorly supported on musl. |
| Base-image pin strategy | Floating tag (`ubuntu-24.04`), NOT `@sha256:` digest | Microsoft's weekly CVE rebuilds flow in automatically. Reproducibility is preserved by digest-pinning our own `:base`/`:agents` downstream and by recording the resolved upstream digest as an OCI annotation per CI build. |
| Version manager stack | **`mise` + `nix` (single-user) + `devbox`**, all three installed | Three distinct roles: `mise` for language runtimes, `nix` for reproducible system CLIs, `devbox` as per-project nix wrapper. They compose without overlap when PATH is ordered shims → nix → apt → user-local. |
| Manager for `nvm`/`pyenv`/`sdkman`-style language pins | **`mise`**, NOT `nix`/`devbox` | `mise` is purpose-built to replace nvm/pyenv/goenv/sdkman with one CLI and one `mise.toml`. Shims-on-PATH works in non-interactive Docker shells without `mise activate`. First-class coverage of all four required languages. `nix`/`devbox` reserved for reproducible system CLIs where a `devbox.lock` (nixpkgs commit hash) provides bit-for-bit reproducibility. |
| Image-level additions | Apt top-up list (derived from `.devcontainer/Dockerfile` lines 7-58), `gh` CLI, Homebrew, mise + nix + devbox, AI agents, MCP plugins, LSPs | Genuine gaps in `base:ubuntu-24.04` (which ships only git/zsh/oh-my-zsh). |
| Image layering | 3 separate Dockerfiles (`base` → `agents` → final) | Required by task; independent rebuilds; smaller per-layer cache invalidation; matches prior task's structure. |
| Registry | `ghcr.io/neolabhq/sandbox` | Required by task; lowercase per GHCR rules. |
| Multi-arch | `linux/amd64` + `linux/arm64` | Apple Silicon parity; matches existing `dpkg --print-architecture` logic. |
| Scripts location | Move to repo root via `mv` (untracked) + `sed -i` for `/home/node/` → `$HOME/` | Required by task; preserves file modes (664/664/775) per `/workspaces/sandbox/.claude/rules/preserve-permissions-on-move.md`; `$HOME/` is user-agnostic so future user-renames don't require another sweep. |
| Non-root user | `vscode` (UID/GID 1000, default in `base:ubuntu-24.04`) | Use the image's existing user — UID-remapping to `node` or `codespace` is brittle (group reshuffling, home-dir ownership gymnastics, conflicts with `docker-outside-of-docker` feature's GID mapping). Script paths are rewritten to `$HOME/` once and the user identity never matters again. |
| nix install mode | Single-user (`--no-daemon`) | Docker containers have no systemd; daemon mode is unnecessary complexity. Single-user install owns `/nix/` as the `vscode` user; profile sourced from `/etc/profile.d/nix.sh`. |
| devbox scope | System-wide install (`/usr/local/bin/devbox`); NO image-level `devbox.json` | Devbox is exposed as a tool; downstream projects drop their own `devbox.json` at their repo root. Baking a global `devbox.json` would force every project to inherit unwanted packages. |
| `nvm`/`pyenv`/`sdkman` retention | NOT installed | Explicitly rejected — would re-introduce manager fragmentation that `mise` is meant to eliminate. Apps that need version pinning use `mise use`. |
| Pip-level helpers (`dvc`, `yq`) | `pip3 install --break-system-packages` against system Python | Ubuntu 24.04 enforces PEP 668; `--break-system-packages` is the documented escape hatch and matches the prior project pattern. The "real" Python that devs use comes from `mise`, so polluting the system Python is acceptable. |
| MCP install timing | `postCreateCommand` (runtime), not build time | Needs `CONTEXT7_API_KEY` only available at container start. |
| `docker-mcp` plugin | Baked into `Dockerfile.agents` | Deterministic build step; eliminates the brittle `bash-command` devcontainer feature. |
| Pipe-fed installers | `SHELL ["/bin/bash", "-o", "pipefail", "-c"]` declared in every Dockerfile | Per `/workspaces/sandbox/.claude/rules/dockerfile-curl-pipe-pipefail.md`; default dash shell does not support pipefail and silently produces empty-install layers on a partial curl. |

---

### File Structure

Files to **create**:
- `/workspaces/sandbox/Dockerfile.base`
- `/workspaces/sandbox/Dockerfile.agents`
- `/workspaces/sandbox/Dockerfile`
- `/workspaces/sandbox/.github/workflows/docker-publish.yml`

Files to **move and edit** (from `.devcontainer/` to repo root; untracked, so `mv` preserves modes per `/workspaces/sandbox/.claude/rules/preserve-permissions-on-move.md`; `sed -i` rewrites `/home/node/` → `$HOME/`):
- `/workspaces/sandbox/.devcontainer/configure-claude.sh` → `/workspaces/sandbox/configure-claude.sh` (mode 664)
- `/workspaces/sandbox/.devcontainer/install-mcps.sh` → `/workspaces/sandbox/install-mcps.sh` (mode 664)
- `/workspaces/sandbox/.devcontainer/statusline.sh` → `/workspaces/sandbox/statusline.sh` (mode 775)

Files to **update**:
- `/workspaces/sandbox/README.md` — full usage documentation including the new mise + nix + devbox section.
- `/workspaces/sandbox/.devcontainer/Dockerfile` — replace contents with a single-line `FROM ghcr.io/neolabhq/sandbox:latest` wrapper.
- `/workspaces/sandbox/.devcontainer/devcontainer.json` — switch `build.dockerfile` → `image`, drop the `bash-command` docker-mcp feature, update `remoteUser` from `"node"` to `"vscode"`.

Files to **leave untouched**:
- `/workspaces/sandbox/.claude/`
- `/workspaces/sandbox/claude-helpers.sh`
- `/workspaces/sandbox/justfile`
- `/workspaces/sandbox/LICENSE`
- `/workspaces/sandbox/.specs/`

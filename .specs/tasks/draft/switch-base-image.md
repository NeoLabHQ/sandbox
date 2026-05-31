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
| `base:debian` / `base:bookworm` | Debian 12 (previous stable) | Smaller footprint than Ubuntu; `bookworm` is the previous Debian stable line. |
| **`base:debian` / `base:trixie`** | **Debian 13 (current stable line; verify GA status at build time via `docker buildx imagetools inspect mcr.microsoft.com/devcontainers/base:trixie --raw`)** | **Smaller footprint than Ubuntu; `trixie` tracks Debian 13, which Debian publishes as the current stable line. Selected — see Decision below.** |
| `base:alpine` | Alpine | Smallest, but musl-libc breaks many prebuilt binaries (Node prebuilt, mise's Rust release artifacts compile but Nix on Alpine is poorly supported). Not suitable here. |

**Decision: `mcr.microsoft.com/devcontainers/base:trixie`** (Debian 13 Trixie) as the base. Rationale: (1) Debian has a materially smaller footprint than Ubuntu derivatives — universal/noble drag in extra recommended packages and locale data we strip anyway, and `base:trixie` is the smallest non-Alpine variant on which `nix` and `devbox` are first-class; (2) `trixie` is Debian's current stable release line (Debian 13; `bookworm` is the previous stable — confirm GA status at build time via `docker buildx imagetools inspect mcr.microsoft.com/devcontainers/base:trixie --raw` and Debian's release notes per `/workspaces/sandbox/.claude/rules/research-version-claims.md`); (3) Ubuntu noble was considered (matches what `universal:6-noble` previously used) but rejected because the size advantage and current-stable cadence of Debian trixie outweigh the minor delta on apt source names; (4) Alpine is rejected outright — `nix` and `devbox` are first-class on glibc-Linux, and Alpine's musl produces friction we do not need; (5) explicit `trixie` (vs the floating `:debian` alias) keeps the OS root explicit in the Dockerfile and is forward-compatible if Microsoft promotes `:debian` to point at the next Debian release.

**Pin strategy: floating codename tag (`trixie`), NOT an immutable `sha256:` digest** — same trade-off as the prior task's plan. Microsoft rebuilds the `base:*` tags on a regular cadence for CVE fixes; pinning a digest freezes us on a known-vulnerable image. Reproducibility for layers we own is recovered downstream:

1. The `build-base` CI job records the resolved upstream digest (`docker buildx imagetools inspect mcr.microsoft.com/devcontainers/base:trixie --format '{{json .Manifest.Digest}}'`) as an OCI annotation on our published `:base`.
2. `Dockerfile.agents` and the final `Dockerfile` digest-pin our **own** layers (`neolabhq/sandbox:base@sha256:<digest>` etc.).
3. Per-run SHA-suffixed tags (`:base-<sha>`, `:agents-<sha>`, `:latest-<sha>`) are published for instant rollback.

**Size comparison (order-of-magnitude only; confirm at build time via `docker image ls`):** `base:trixie` is roughly an order of magnitude smaller compressed than `universal:6-noble` because the universal image bundles Node, Python, Go, Java, Ruby, PHP, .NET, Conda plus their managers (~1-2 GB of runtimes), and Debian's minimal package set is itself smaller than Ubuntu's. After we re-add the four languages we actually need via mise/nix on top of `base`, the resulting image is still expected to be materially smaller than universal — the user's stated motivation for this migration. Record the actual numbers in the workflow build summary (Step 5) so the README's "Image variants" section quotes verified sizes, not estimates.

A fourth image, `Dockerfile.universal`, is layered on top of the final `Dockerfile` to provide the broader language stack, simular to `devcontainers/universal` shipped (Ruby, PHP, .NET, Rust, Zig, plus the C++ toolchain already in `Dockerfile.base` via `build-essential`). It is published as `neolabhq/sandbox:universal` for users who want a drop-in universal-image replacement; the minimal `:latest` remains the default. See **Step 4: Create `Dockerfile.universal`** below for the full plan.

```dockerfile
FROM mcr.microsoft.com/devcontainers/base:trixie
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

For project-specific overrides, a downstream repo drops a `mise.toml` at its root (or a `devbox.json` for nix-managed tooling); both are detected automatically by an **entrypoint script** that runs before the user's shell is started. The same entrypoint also conditionally registers MCP servers based on environment-variable presence (replacing the prior unconditional `install-mcps.sh` invocation). The README section that documents this behavior is drafted below; this draft is the canonical source for **README section 8 "Language version manager stack"** (see Step 6).

##### README draft: entrypoint-driven autodetection for `mise.toml` / `devbox.json` and MCP servers

**(a) Entrypoint contract.** The published image installs a shell entrypoint at `/opt/devcontainer/entrypoint.sh` and wires it as the Dockerfile `ENTRYPOINT` (see Step 3). The entrypoint runs as the `vscode` user, prepares the per-project shell environment, and then `exec`s the requested command (defaults to `bash`). It performs two autodetections, in this order, against the current working directory (`$PWD`) and any ancestor up to `/`:

1. **Language-runtime activation.** If a `devbox.json` is found, `devbox shell -- exec "$@"` is invoked so the project's pinned nixpkgs profile is prepended to PATH. Else if a `mise.toml`, `.mise.toml`, or `.tool-versions` file is found, the entrypoint runs `mise install` (idempotent) to ensure the pinned versions are materialized, then `exec`s the command under `mise exec --` so project-level pins win over image globals. If neither is present, the image-level globals from Step 1 (`mise use --global ...`) apply and the entrypoint falls through to a plain `exec`.
2. **MCP server registration.** For each MCP server, the entrypoint checks the relevant environment variable(s) (listed in (c) below) and only registers that server when its variable is non-empty. This subsumes — and replaces at the published-image level — the unconditional `.devcontainer/install-mcps.sh` logic that previously ran as `postCreateCommand`. Local devcontainer usage continues to invoke `.devcontainer/install-mcps.sh` as-is (the local environment is preserved unchanged); published-image consumers rely on the entrypoint instead.

**(b) Autodetection priority.** Detection walks up from `$PWD` toward `/`, taking the first match. For runtime files the order at any single directory is `devbox.json` → `mise.toml` → `.mise.toml` → `.tool-versions`. For MCP servers detection is environment-variable-based and does not walk the filesystem.

**(c) MCP environment variables that gate autodetection.** Each variable, when set to a non-empty value, opts the corresponding MCP server in:

| Variable | MCP server | Effect when set |
|----------|------------|-----------------|
| `CONTEXT7_API_KEY` | Context7 | `claude mcp add --scope user --transport http context7 https://mcp.context7.com/mcp --header "CONTEXT7_API_KEY: $CONTEXT7_API_KEY"` |
| `DOCKER_MCP_SERVER` | Docker MCP gateway | Runs `docker mcp` setup so the baked plugin's profiles/catalog are activated for the current container session |

When none of the variables are set the entrypoint logs a single line (`"No MCP env vars detected; skipping MCP registration."`) and proceeds.

**(d) Example snippets.**

```toml
# mise.toml at the project root
[tools]
node = "20.11.0"
python = "3.12"
go = "1.22"

[env]
NODE_OPTIONS = "--max-old-space-size=4096"
```

```json
// devbox.json at the project root
{
  "packages": [
    "pre-commit@latest",
    "lefthook@latest",
    "tree-sitter@latest"
  ],
  "shell": {
    "init_hook": ["pre-commit install --install-hooks"]
  }
}
```

**(e) Interoperation — same role boundary as the image-level decision.** `mise` owns *language runtimes* in the project file just as it does at the image level: Node, Python, Go, Java, Ruby, Deno, Bun, etc. `devbox` owns *system CLIs and libraries* a project pins via nixpkgs: linters, formatters, language-server-style developer tools, anything where bit-for-bit reproducibility through a nixpkgs commit is preferred over a tarball-fetching version manager. The two compose cleanly because devbox's nix profile entries land on PATH before the mise shims when `devbox shell` activates, but the mise shims still resolve language binaries because devbox does not install Node/Python/Go/Java by default.

**(f) Precedence.** From highest to lowest priority for any given tool:

1. **Project file** (`devbox.json` for system CLIs; `mise.toml` / `.mise.toml` / `.tool-versions` for runtimes) — first match walking up from `$PWD`, activated by the entrypoint.
2. **User global** (`~/.config/mise/config.toml`; `devbox global` profile) — applies when no project file overrides.
3. **Image global** (`mise use --global` from Step 1; the system-wide `nix`+`devbox` install) — fallback that ships in the image and applies when neither of the above is present.

The runtime-verifiable command that surfaces which level is active for a given tool is `mise current` (run from inside the project) — it lists each tool with the file path that supplied the pin. For devbox the equivalent is `devbox info` from inside the project shell.

#### Missing tooling vs `devcontainers/base`

Derived by reading `/workspaces/sandbox/.devcontainer/Dockerfile` lines 7-103 (the current legacy image's stage 1+2 installs) and cross-referencing against the `base-debian` README and Dockerfile (which install only `git`, `zsh`, Oh My Zsh!, and `tzdata` reinstall — see https://github.com/devcontainers/images/blob/main/src/base-debian/.devcontainer/Dockerfile).

**Top-up list — must be added in `Dockerfile.base` because `base:trixie` does not ship them:**

apt packages (lines 7-58 of current Dockerfile, adjusted for Debian trixie — verify each name resolves at build time via `apt-cache show <pkg>` in a transient `base:trixie` container): `apt-utils`, `bash-completion`, `openssh-client`, `gnupg2`, `dirmngr`, `iproute2`, `procps`, `lsof`, `htop`, `net-tools`, `psmisc`, `curl`, `tree`, `wget`, `rsync`, `ca-certificates`, `unzip`, `bzip2`, `xz-utils`, `zip`, `nano`, `vim-tiny`, `less`, `jq`, `lsb-release`, `apt-transport-https`, `dialog`, `libc6`, `libgcc-s1`, `libkrb5-3`, `libgssapi-krb5-2`, `libicu[0-9][0-9]`, `liblttng-ust[0-9]`, `libstdc++6`, `zlib1g`, `locales`, `sudo`, `ncdu`, `man-db`, `strace`, `manpages`, `manpages-dev`, `init-system-helpers`, `build-essential`, `file`, `retry`, `python3`, `python3-pip` (the last two are only kept as a bootstrap for `pip install dvc yq`; the real Python that devs use comes from `mise`). Notes for Debian trixie: (a) the `libgcc-s1` package name is used directly — `libgcc1` is not the package name on trixie either, so the canonical name `libgcc-s1` is used unconditionally; (b) the `libicu[0-9][0-9]` glob matches whatever `libicuNN` SONAME ships in trixie's archive (verify at build time via `apt-cache search '^libicu[0-9][0-9]$'` in a transient `base:trixie` container); (c) `liblttng-ust[0-9]` likewise matches the trixie-shipped SONAME (`liblttng-ust1` historically); (d) `python3-pip` is still the correct name, but Debian trixie enforces PEP 668 ("externally-managed-environment") just as Ubuntu 24.04 does — the `--break-system-packages` escape hatch is still required for `dvc`/`yq` (see below).

Standalone installs (lines 64-103 of current Dockerfile): **`gh` CLI** (explicit example from the draft — its apt repo + key install on lines 64-73; the install snippet is already cross-platform because it uses `dpkg --print-architecture` rather than a hard-coded Ubuntu codename, and the `https://cli.github.com/packages stable main` apt repo serves Debian and Ubuntu from the same suite), **Homebrew (Linuxbrew)** (line 99), and the npm globals `typescript-language-server typescript rust-just bun` (line 103) — the npm globals move to `Dockerfile.agents` because they require the mise-managed Node to exist.

NOT re-installed at apt level (because `mise` now owns them): `nvm`, `nodejs`, `python3` (as runtime), `golang-go`, `default-jdk` — all four come from `mise install` instead.

New additions (not in the current `.devcontainer/Dockerfile` but required by this task): `mise`, `nix` (single-user), `devbox`.

#### AI Coding Agents

Identical to the prior task's plan — no provider has changed installer commands. Installer commands carried over verbatim:

- **Claude Code** — `curl -fsSL https://claude.ai/install.sh | bash`. Installs to `~/.local/bin/claude`.
- **OpenCode** — `curl -fsSL https://opencode.ai/install | bash`. Installs as `opencode`.
- **Gemini CLI** — `npm install -g @google/gemini-cli` (requires Node ≥ 20 — guaranteed by `mise` pinning `node@lts`).
- **Codex (OpenAI)** — `npm install -g @openai/codex`.
- **`pi`** — install per the upstream project's canonical installer. The exact package name and install command are not asserted here per `/workspaces/sandbox/.claude/rules/research-version-claims.md`; at implementation time, verify the upstream `pi` project README (start by searching the GitHub `pi-agent` / `oh-my-pi` ecosystem) and use whichever of the standard install patterns it publishes — `npm install -g <package>` if it ships an npm package, or `curl -fsSL <upstream-installer-url> | bash` if it ships a shell installer. Record the resolved install URL in the CI build summary so it is verifiable at build time.
- **`oh-my-pi`** — companion configuration framework for `pi` (mirroring the `oh-my-zsh` relationship to `zsh`). Install per its upstream README — typically `git clone <upstream-repo> ~/.oh-my-pi && ~/.oh-my-pi/install.sh` for an oh-my-zsh-style framework, but verify the canonical command at implementation time and do not bake in a fabricated URL. Like Claude Code's install path, expect this to land under the `vscode` user's home (`~/.oh-my-pi` or `~/.local/share/oh-my-pi`).

All six install cleanly under the `vscode` user's home; no root-level changes beyond ensuring `PATH` includes `~/.local/bin` and the npm global prefix.

#### MCP Servers

- **Context7** — registered at container start by the new `entrypoint.sh` (see Step 3) when `CONTEXT7_API_KEY` is non-empty: `claude mcp add --scope user --transport http context7 https://mcp.context7.com/mcp --header "CONTEXT7_API_KEY: $CONTEXT7_API_KEY"`. The legacy `.devcontainer/install-mcps.sh` (preserved unchanged in the local devcontainer environment) continues to run as `postCreateCommand` for local devcontainer usage; published-image consumers rely on the entrypoint instead.
- **Codemap** — Go binary built from `https://github.com/JordanCoin/codemap`. Built in `Dockerfile.agents` using the mise-managed Go.
- **Language servers** — `typescript-language-server` (npm), `pyright` (npm), `gopls` (`go install golang.org/x/tools/gopls@latest`), `jdtls` (Eclipse JDT tarball under `/opt/jdtls`). All installed in `Dockerfile.agents`.
- **`docker-mcp` CLI plugin** — baked into `Dockerfile.agents` so it ships with the published image (same rationale as the prior plan: it's deterministic, doesn't need host state, and saves ~30-60s on every plain `docker run` start). The local `.devcontainer/devcontainer.json`'s existing `bash-command` feature that installs `docker-mcp` at devcontainer-create time is left unchanged because **`.devcontainer/` is preserved unchanged** by this task (see Technical Decisions: "`.devcontainer/` treatment") — it will simply redo the install over the already-baked plugin during local dev, which is acceptable for a regression-tolerant local environment. At published-image runtime, the `entrypoint.sh` (Step 3) activates the docker-mcp setup when `DOCKER_MCP_SERVER` is set.

#### GitHub Container Registry Workflow

Same shape as the prior plan, three sequential jobs (`build-base` → `build-agents` → `build-final`), each pushing to `neolabhq/sandbox` (lowercase org, GHCR rule). Differences vs the prior plan:

- The `build-base` job's matrix-of-base-image-digests now records `mcr.microsoft.com/devcontainers/base:trixie` rather than `universal:6-noble`.
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

#### Step 1: Modify `Dockerfile.base`

Modify `/workspaces/sandbox/Dockerfile.base` (file already exists in the repo; this step rewrites it for the Debian trixie base).

- `FROM mcr.microsoft.com/devcontainers/base:trixie` — no digest pin (see Base Image rationale).
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
  (Note for Debian trixie: `libgcc-s1` is the canonical package name; the `libicu[0-9][0-9]` and `liblttng-ust[0-9]` globs resolve to whichever SONAME ships in trixie's archive — verify at build time via `apt-cache search '^libicu[0-9][0-9]$'` in a transient `base:trixie` container. PEP 668 enforcement applies on trixie as well, so the later `pip3 install --break-system-packages dvc yq` step is still required.)
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
- Install pip-level helpers used by existing scripts (`dvc`, `yq`) into the system Python with `--break-system-packages` (Debian trixie enforces PEP 668's "externally-managed-environment" the same way Ubuntu 24.04 does):
  ```dockerfile
  USER root
  RUN pip3 install --break-system-packages dvc yq
  ```
- **Non-root user: `vscode`** (UID/GID 1000, shipped by `base:trixie`). We do NOT create a `node` or `codespace` user. `.devcontainer/` is preserved unchanged for the local development environment; the published image's final `Dockerfile` `COPY`s the scripts directly from `.devcontainer/` and the scripts already use `$HOME` (no hard-coded `/home/<user>/` paths — verified via `grep -n 'HOME\|/home' .devcontainer/*.sh` at task-plan time), so they resolve correctly under the `vscode` user — see Step 3.

Output image tag: `neolabhq/sandbox:base`.

#### Step 2: Modify `Dockerfile.agents`

Modify `/workspaces/sandbox/Dockerfile.agents` (file already exists in the repo; this step rewrites it for the new agents stack).

- `ARG BASE_IMAGE=neolabhq/sandbox:base`
- `FROM ${BASE_IMAGE}` — CI pins this to `:base@sha256:<digest>` resolved by the `build-base` job.
- `SHELL ["/bin/bash", "-o", "pipefail", "-c"]` per the curl-pipe rule.
- `USER vscode`.
- Install **Claude Code**: `curl -fsSL https://claude.ai/install.sh | bash`. Ensure `PATH` includes `/home/vscode/.local/bin`.
- Install **OpenCode**: `curl -fsSL https://opencode.ai/install | bash`.
- Install **Gemini CLI**: `npm install -g @google/gemini-cli` (`mise`-managed Node from Step 1; npm global prefix is the user's home so no `sudo`).
- Install **Codex CLI**: `npm install -g @openai/codex`.
- Install **`pi` agent** — hedged per `/workspaces/sandbox/.claude/rules/research-version-claims.md`: do NOT bake a fabricated install URL into the Dockerfile. At implementation time, look up the canonical `pi` install command from the upstream README and use whichever of these two patterns the project publishes:
  ```dockerfile
  # Variant A — if upstream ships an npm package:
  # RUN npm install -g <verified-pi-package-name>
  # Variant B — if upstream ships a shell installer:
  # RUN curl -fsSL <verified-upstream-installer-url> | bash
  # Pick the variant the upstream README documents; record the resolved
  # URL/package in the CI build summary so it is verifiable at build time.
  ```
- Install **`oh-my-pi`** — same hedging policy. Expect an `oh-my-zsh`-style framework install (`git clone <upstream-repo> ~/.oh-my-pi && ~/.oh-my-pi/install.sh` or equivalent); verify the canonical command at implementation time:
  ```dockerfile
  # RUN git clone --depth 1 <verified-oh-my-pi-repo-url> /home/vscode/.oh-my-pi \
  #  && /home/vscode/.oh-my-pi/install.sh
  ```
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
- Install **`docker-mcp` CLI plugin** (baked here so the plugin ships with the published image; the local `.devcontainer/devcontainer.json`'s existing `bash-command` feature is left unchanged because `.devcontainer/` is preserved unchanged by this task — see Technical Decisions: "`.devcontainer/` treatment"):
  ```dockerfile
  USER vscode
  RUN git clone --depth 1 https://github.com/docker/mcp-gateway.git /tmp/mcp-gateway \
   && cd /tmp/mcp-gateway \
   && mkdir -p /home/vscode/.docker/cli-plugins \
   && HOME=/home/vscode DOCKER_MCP_CLI_PLUGIN_DST=/home/vscode/.docker/cli-plugins/docker-mcp make docker-mcp \
   && rm -rf /tmp/mcp-gateway
  ```
  Runtime Docker CLI comes from the devcontainer's `docker-outside-of-docker` feature.

Output image tag: `neolabhq/sandbox:agents`.

#### Step 3: Modify final `Dockerfile` and create `entrypoint.sh`

Modify `/workspaces/sandbox/Dockerfile` (file already exists in the repo; this step rewrites it) and create `/workspaces/sandbox/entrypoint.sh` (new file at repo root — `.devcontainer/` is preserved unchanged per the Technical Decisions table, so the new entrypoint script lives at the repo root and is owned by the published image only).

- `ARG AGENTS_IMAGE=neolabhq/sandbox:agents`
- `FROM ${AGENTS_IMAGE}` — digest-pinned by the `build-agents` CI job.
- `SHELL ["/bin/bash", "-o", "pipefail", "-c"]` per `/workspaces/sandbox/.claude/rules/dockerfile-curl-pipe-pipefail.md`.
- `USER root`
- `COPY .devcontainer/configure-claude.sh .devcontainer/statusline.sh .devcontainer/install-mcps.sh entrypoint.sh /opt/devcontainer/` — sources the three shell scripts directly from `.devcontainer/` (which is preserved unchanged by this task) and the new `entrypoint.sh` from the repo root.
- `RUN chmod +x /opt/devcontainer/*.sh`
- `ENV DOCKER_MCP_IN_CONTAINER=1`
- `USER vscode`
- **Verify codemap and language MCP servers are present** (inherited from agents image): `RUN command -v codemap && command -v gopls && command -v pyright && command -v jdtls` — fails fast if the agents image ever drops one.
- `RUN /opt/devcontainer/configure-claude.sh` — bootstraps `~/.claude/settings.json`, statusline, and Claude plugins.
- Do NOT run `install-mcps.sh` at build time — it needs `CONTEXT7_API_KEY` only available at runtime. The new `entrypoint.sh` (below) takes over MCP registration at container start for published-image consumers; the local `.devcontainer/devcontainer.json` continues to call `install-mcps.sh` as its `postCreateCommand` unchanged.
- `WORKDIR /workspaces`
- `ENTRYPOINT ["/opt/devcontainer/entrypoint.sh"]`
- `CMD ["sleep","infinity"]`

**`entrypoint.sh` contract** (canonical reference for the README draft in Research Findings → Languages):

1. Run as `vscode`. Idempotent — safe to invoke twice.
2. Walk up from `$PWD` looking for `devbox.json` first, then `mise.toml` / `.mise.toml` / `.tool-versions`. If `devbox.json` is found, activate via `devbox shell -- "$@"`. Else if a mise file is found, run `mise install` (no-op when versions already match) and `exec mise exec -- "$@"`. Else fall through to plain `exec "$@"` (image globals from Step 1 apply).
3. For each MCP env var listed in the README draft's table (c), conditionally register the corresponding MCP server. The Context7 block mirrors `.devcontainer/install-mcps.sh` (the local script is preserved unchanged), and the Docker MCP block gates on `DOCKER_MCP_SERVER`.
4. Log skipped detections so absence is observable (`"No mise/devbox project file detected — falling back to image globals."`, `"No MCP env vars detected; skipping MCP registration."`).

Skeleton (no `curl ... | bash` lines, so the `SHELL` pipefail declaration in the Dockerfile already covers this file when it runs from `RUN` contexts; `entrypoint.sh` itself uses `set -euo pipefail` directly):

```bash
#!/usr/bin/env bash
set -euo pipefail

# (1) Project-runtime autodetection
find_up() {
  local name="$1" dir="$PWD"
  while [ "$dir" != "/" ]; do
    [ -e "$dir/$name" ] && { printf '%s\n' "$dir/$name"; return 0; }
    dir="$(dirname "$dir")"
  done
  return 1
}

activator=()
if find_up devbox.json >/dev/null; then
  activator=(devbox shell --)
elif find_up mise.toml >/dev/null || find_up .mise.toml >/dev/null || find_up .tool-versions >/dev/null; then
  mise install >/dev/null
  activator=(mise exec --)
else
  echo "No mise/devbox project file detected — falling back to latest runtime versions."
fi

echo "Node: $(node --version)"
echo "Python: $(python3 --version)"
echo "Go: $(go version)"
echo "Java: $(java --version)"

# (2) MCP autodetection (env-var-gated; mirrors .devcontainer/install-mcps.sh)
mcp_registered=0
if [ -n "${CONTEXT7_API_KEY:-}" ]; then
  claude mcp add --scope user --transport http context7 \
    https://mcp.context7.com/mcp \
    --header "CONTEXT7_API_KEY: ${CONTEXT7_API_KEY}" || true
  mcp_registered=1
  echo "Context7 MCP server registered."
fi
if [ -n "${DOCKER_MCP_SERVER:-}" ]; then
  docker mcp --help >/dev/null 2>&1 && mcp_registered=1
  echo "Docker MCP server registered."
fi
[ "$mcp_registered" = "0" ] && echo "No MCP env vars detected; skipping MCP registration."

# (3) Hand off
if [ "${#activator[@]}" -gt 0 ]; then
  exec "${activator[@]}" "$@"
fi
exec "$@"
```

Output image tag: `neolabhq/sandbox:latest`.

#### Step 4: Create `Dockerfile.universal`

Create `/workspaces/sandbox/Dockerfile.universal` — a fourth image layered on top of the final `Dockerfile` that adds the broader language stack `devcontainers/universal` ships and our minimal `:latest` deliberately omits. Published as `neolabhq/sandbox:universal` so downstream consumers who actually need the universal-style language set can pull a drop-in replacement without paying the size cost on `:latest`.

Languages added on top of `:latest` (Java is already baked via `mise` in Step 1 and is NOT duplicated; C++ toolchain is already covered by `build-essential` in `Dockerfile.base` and is NOT duplicated):

| Language | Manager owner | Rationale |
|----------|---------------|-----------|
| Ruby | `mise` (first-class plugin) | Same shims-on-PATH model as the other mise-managed runtimes; verify plugin support at implementation time via `mise plugin list-all \| grep ruby`. |
| Rust | `mise` (first-class plugin) | Same as above; `cargo` lands under the mise shims. Verify at implementation time. |
| Zig | `mise` (first-class plugin) | Same as above. Verify at implementation time. |
| PHP | apt (`php-cli`, `php-common`, plus the project-relevant extensions: `php-mbstring`, `php-xml`, `php-curl`, `php-zip`) | mise's PHP plugin requires building from source (slow, large toolchain); apt's `php-cli` on Debian trixie is well-maintained. Composer installed separately via the upstream installer. |
| .NET | Microsoft's apt repo (`packages-microsoft-prod` for Debian trixie → `dotnet-sdk-<current-LTS>`) | Microsoft publishes Debian apt repos per release; verify the trixie repo URL at implementation time. .NET on `nix` is also viable; we prefer Microsoft's apt repo for parity with how `devcontainers/universal` shipped it. |

Dockerfile structure:

```dockerfile
ARG FINAL_IMAGE=neolabhq/sandbox:latest
FROM ${FINAL_IMAGE}
SHELL ["/bin/bash", "-o", "pipefail", "-c"]   # per /workspaces/sandbox/.claude/rules/dockerfile-curl-pipe-pipefail.md
USER root

# 1. PHP from apt (Debian trixie's php-cli is current; verify version at build time).
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      php-cli php-common php-mbstring php-xml php-curl php-zip \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. Composer (verify upstream installer URL at build time).
RUN curl -fsSL https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# 3. .NET SDK via Microsoft's Debian apt repo (verify the trixie URL at implementation time;
#    Microsoft publishes per-codename repo paths under https://packages.microsoft.com/config/debian/).
RUN curl -fsSL https://packages.microsoft.com/config/debian/13/packages-microsoft-prod.deb -o /tmp/ms-prod.deb \
 && dpkg -i /tmp/ms-prod.deb && rm /tmp/ms-prod.deb \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends dotnet-sdk-8.0 \
 && apt-get clean && rm -rf /var/lib/apt/lists/*
# Note: the dotnet-sdk-8.0 package name is hedged per the version-claims rule — verify the
# current-LTS .NET package name (likely a higher major) at implementation time.

USER vscode

# 4. Ruby, Rust, Zig via mise (first-class plugins — verify each at implementation time
#    against `mise plugin list-all`).
RUN mise use --global ruby@latest rust@latest zig@latest \
 && mise install \
 && mise reshim
```

Output image tag: `neolabhq/sandbox:universal`.

A `build-universal` CI job is added to `.github/workflows/docker-publish.yml` with `needs: [lint, build-final]`, so the chain becomes `lint → base → agents → final → universal`. The job mirrors the build/scan/push shape of `build-final`, pushing `:universal` and `:universal-<sha>` for rollback. See Step 5 below for the full CI changes.

#### Step 5: Modify `.github/workflows/docker-publish.yml`

Modify `/workspaces/sandbox/.github/workflows/docker-publish.yml` (file already exists in the repo).

Triggers: `push` to `master`, `workflow_dispatch`, tag pushes (`v*`).

Permissions: `contents: read`, `packages: write`, `security-events: write` (for SARIF upload).

A separate `lint` job runs first and is a `needs:` dependency of all four build jobs. This enforces `/workspaces/sandbox/.claude/rules/dockerfile-curl-pipe-pipefail.md` at CI time by running hadolint with `DL4006` enabled across every `Dockerfile*` in the repo. Placing the linter in its own job (rather than a per-build pre-step) lints all four Dockerfiles in one place, fails fast before any image is built, and keeps the build jobs focused on build/scan/push.

0. **`lint`** — `hadolint/hadolint-action@v3` runs against `Dockerfile.base`, `Dockerfile.agents`, `Dockerfile`, `Dockerfile.universal`, and `.devcontainer/Dockerfile`. Configure with `failure-threshold: warning` and an inline `--require-label DL4006=error` (or an equivalent `.hadolint.yaml` enabling rule `DL4006`) so any `curl ... | bash` line without a preceding `SHELL ["/bin/bash", "-o", "pipefail", "-c"]` is rejected. Cross-reference: `/workspaces/sandbox/.claude/rules/dockerfile-curl-pipe-pipefail.md`. Example step:
   ```yaml
   - name: Lint Dockerfiles (enforce DL4006 / curl|bash pipefail)
     uses: hadolint/hadolint-action@v3
     with:
       dockerfile: Dockerfile.base
       failure-threshold: warning
       override-error: DL4006
   ```
   Repeat for `Dockerfile.agents`, `Dockerfile`, `Dockerfile.universal`, and `.devcontainer/Dockerfile` (or use a single `recursive: true` invocation if the action version in use supports it — verify against the action's release notes at build time).

Four sequential build jobs (each declares `needs: lint` so a hadolint failure short-circuits the whole pipeline). The build chain is `lint → base → agents → final → universal`:

1. **`build-base`** — `needs: lint`. `docker/build-push-action@v6` builds `Dockerfile.base`, scans with Trivy, then pushes `neolabhq/sandbox:base` AND `:base-<sha>`. Records the resolved `mcr.microsoft.com/devcontainers/base:trixie` digest as an OCI annotation and into the build summary.
2. **`build-agents`** — `needs: [lint, build-base]`. `build-args: BASE_IMAGE=neolabhq/sandbox:base@sha256:<digest>` from job 1's output. Pushes `:agents` and `:agents-<sha>`.
3. **`build-final`** — `needs: [lint, build-agents]`. `build-args: AGENTS_IMAGE=neolabhq/sandbox:agents@sha256:<digest>`. Pushes `:latest` and `:latest-<sha>`.
4. **`build-universal`** — `needs: [lint, build-final]`. `build-args: FINAL_IMAGE=neolabhq/sandbox:latest@sha256:<digest>` from job 3's output. Pushes `:universal` and `:universal-<sha>`. Same `cache-from`/`cache-to` discipline as the other jobs but with `scope=universal` so a universal-only change doesn't invalidate the final-layer cache.

Each job:
- `actions/checkout@v4`
- `docker/setup-qemu-action@v3`, `docker/setup-buildx-action@v3`
- `docker/login-action@v3` (registry `ghcr.io`, password `${{ secrets.GITHUB_TOKEN }}`)
- `docker/metadata-action@v5` for tag generation
- **Build → scan → push**: first `build-push-action` invocation with `push: false, load: true` for single-arch local scan; `aquasecurity/trivy-action` (latest stable, pinned by SHA at PR-merge time per the curl-pipe-and-version-pin discipline) with `severity: CRITICAL,HIGH, exit-code: 1, ignore-unfixed: true`; SARIF upload via `github/codeql-action/upload-sarif@v3`; SBOM via `anchore/sbom-action@v0`; final `build-push-action` with `push: true, platforms: linux/amd64,linux/arm64, cache-from/to: type=gha,scope=<base|agents|final|universal>`.

Note: org name in GHCR must be lowercase (`neolabhq/sandbox`).

Optional but recommended: a separate scheduled workflow (`cron`) re-scans the latest `:base`, `:agents`, `:latest`, and `:universal` weekly.

##### Rollback plan

Same shape as the prior plan, adapted for the new base:

- Every workflow run pushes immutable `:base-<sha>`, `:agents-<sha>`, `:latest-<sha>`, `:universal-<sha>`. To restore service: `docker buildx imagetools create -t neolabhq/sandbox:latest neolabhq/sandbox:latest-<previous-good-sha>` — atomic at the registry, no rebuild. (Same pattern applies to `:universal`.)
- Revert digest pins in `Dockerfile.agents` / final `Dockerfile` / `Dockerfile.universal` to a previous good `:base@sha256:<digest>` / `:agents@sha256:<digest>` / `:latest@sha256:<digest>` and re-run. `.devcontainer/Dockerfile` is preserved as-is by this task (see Technical Decisions: "`.devcontainer/` treatment") and is not part of the published-image rollback path.
- For an upstream Microsoft regression (the floating `base:trixie` tag rebuild went bad): emergency-pin `Dockerfile.base` to `mcr.microsoft.com/devcontainers/base:trixie@sha256:<last-good>` recorded in the `build-base` OCI annotation, then revert to the floating tag once upstream stabilizes.
- Invalidate poisoned GHA cache scopes via `gh actions-cache delete` so bad layers are not silently reused.

#### Step 6: Update `README.md`

Replace the current README with comprehensive docs. Same outline as the prior plan, with paths updated to `/home/vscode/...` and a new section explicitly documenting the mise + nix + devbox stack:

1. **Overview** — what the image is, what's preinstalled (mise-managed Node/Python/Go/Java + nix + devbox + AI agents + MCP plugins + LSPs).
2. **Image variants & tags** — `:base`, `:agents`, `:latest`, **`:universal`** (drop-in replacement for `devcontainers/universal` — adds Ruby/PHP/.NET/Rust/Zig on top of `:latest`), plus immutable `:<variant>-<sha>` tags.
3. **Quick start with Docker (persistent setup)** — `~/.claude` and `~/.claude.json` mapped to `/home/vscode/...`.
4. **Quick start without persistent Claude state (ephemeral / CI)** — `CLAUDE_CODE_OAUTH_TOKEN` only.
5. **Volume mapping for projects** — workspace mount + Claude mounts + optional SSH/git config.
6. **Mounting multiple project directories** — multi-`-v` pattern under `/workspaces`.
7. **Passing `CLAUDE_CODE_OAUTH_TOKEN`** — `claude setup-token` on host; mention `ANTHROPIC_API_KEY` and `CONTEXT7_API_KEY`.
8. **Language version manager stack (mise + nix + devbox) and entrypoint-driven autodetection** — NEW section. The canonical content for this section is drafted under Research Findings → Languages → "README draft: entrypoint-driven autodetection for `mise.toml` / `devbox.json` and MCP servers" above; the README narrative is a polished version of that draft, covering (a) the entrypoint contract (runs before the user shell), (b) autodetection priority walking up from `$PWD` (`devbox.json` → `mise.toml`/`.mise.toml`/`.tool-versions`), (c) the table of MCP environment variables that gate registration (`CONTEXT7_API_KEY`, `DOCKER_MCP_SERVER`), (d) example snippets, (e) the mise/devbox interop boundary, (f) project > user > image precedence. The README MUST explicitly state: "Autodetection of project runtimes is based on the presence of `mise.toml` / `.mise.toml` / `.tool-versions` / `devbox.json`. MCP autodetection is based on the presence of the listed environment variables." Quote the same runtime-verifiable commands the draft references:
   - `docker run --rm neolabhq/sandbox:latest bash -lc 'mise --version && mise current && node --version && python3 --version && go version && java --version'`
   - `docker run --rm neolabhq/sandbox:latest bash -lc 'nix --version && nix-env -q'`
   - `docker run --rm neolabhq/sandbox:latest bash -lc 'devbox version'`
   - `docker run --rm -e CONTEXT7_API_KEY=dummy neolabhq/sandbox:latest bash -lc 'cat /opt/devcontainer/entrypoint.sh >/dev/null && echo entrypoint-present'` — confirms the entrypoint shipped.
9. **Using as a devcontainer (downstream-consumer example)** — this section is a guide for *users of the published image* who want to consume it as their devcontainer base. It is NOT a description of changes we make to this repo's `.devcontainer/` (which is preserved unchanged for local development/testing). Quick setup (`"image": "neolabhq/sandbox:latest"` + `docker-outside-of-docker` feature + `"remoteUser": "vscode"`) and a Docker-MCP setup variant.
10. **Tools included** — list languages (hedged per `/workspaces/sandbox/.claude/rules/research-version-claims.md`: "Node, Python, Go, Java — managed by `mise` at current-LTS / current-stable defaults; exact resolved versions are documented in the CI build summary"), version managers (`mise` + `nix` + `devbox`), agents (Claude Code, OpenCode, Gemini CLI, Codex, `pi`, `oh-my-pi`), MCP servers (Context7, codemap, docker-mcp), LSPs (gopls, pyright, jdtls, typescript-language-server), plus Homebrew and `gh` CLI. Note `:universal` adds Ruby/PHP/.NET/Rust/Zig.
11. **Building locally** — `docker build -f Dockerfile.base -t sandbox:base .` chain, extended with `Dockerfile.universal` at the end.

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
  neolabhq/sandbox:latest \
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
  neolabhq/sandbox:latest \
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
  neolabhq/sandbox:latest \
  bash
```

The README will note: (1) keep each project in its own sub-directory under `/workspaces/` — agents and LSPs locate project roots by walking up to the nearest `.git`/`pyproject.toml`/`go.mod`/etc., so siblings stay isolated; (2) cross-project refactors work because all projects share one container PATH, `gh` auth, and Claude session; (3) for write isolation use `:ro` on the read-only mounts (e.g., a vendored monorepo dependency mounted as `-v "$HOME/code/shared-lib:/workspaces/shared-lib:ro"`).

##### Example: quick devcontainer setup

```jsonc
{
  "name": "NeoLabHQ Sandbox",
  "image": "neolabhq/sandbox:latest",
  "features": {
    "devcontainers/features/docker-outside-of-docker:1": {}
  },
  "remoteUser": "vscode",
  "remoteEnv": {
    "CLAUDE_CODE_OAUTH_TOKEN": "${localEnv:CLAUDE_CODE_OAUTH_TOKEN}",
    "ANTHROPIC_API_KEY": "${localEnv:ANTHROPIC_API_KEY}",
    "CONTEXT7_API_KEY": "${localEnv:CONTEXT7_API_KEY}"
  }
  // MCP registration is handled automatically by the image ENTRYPOINT
  // (/opt/devcontainer/entrypoint.sh) based on CONTEXT7_API_KEY presence.
  // No postCreateCommand is required for the default published image.
}
```

##### Example: devcontainer with Docker MCP

```jsonc
{
  "name": "NeoLabHQ Sandbox (Docker MCP)",
  "image": "neolabhq/sandbox:latest",
  "features": {
    "devcontainers/features/docker-outside-of-docker:1": {}
  },
  "mounts": [
    "source=${localEnv:HOME}/.docker/mcp,target=/home/vscode/.docker/mcp,type=bind,consistency=cached"
  ],
  "remoteUser": "vscode",
  "remoteEnv": {
    "CLAUDE_CODE_OAUTH_TOKEN": "${localEnv:CLAUDE_CODE_OAUTH_TOKEN}",
    "CONTEXT7_API_KEY": "${localEnv:CONTEXT7_API_KEY}",
    "DOCKER_MCP_SERVER": "1",
    "DOCKER_MCP_CATALOG_DIR": "/home/vscode/.docker/mcp"
  }
  // Setting DOCKER_MCP_SERVER opts the docker-mcp branch of
  // /opt/devcontainer/entrypoint.sh in; Context7 is auto-registered via CONTEXT7_API_KEY.
  // The local repo's `.devcontainer/install-mcps.sh` is preserved unchanged and remains
  // available at /opt/devcontainer/install-mcps.sh for projects that prefer an explicit
  // `postCreateCommand` invocation instead of the entrypoint behavior.
}
```

Outbound links:
- Docker MCP Catalog & Toolkit: https://docs.docker.com/ai/mcp-catalog-and-toolkit/
- `docker/mcp-gateway`: https://github.com/docker/mcp-gateway
- mise: https://mise.jdx.dev / https://mise.jdx.dev/mise-cookbook/docker.html
- nix (single-user): https://nix.dev/manual/nix/stable/installation/single-user
- devbox: https://github.com/jetify-com/devbox / https://www.jetify.com/devbox/docs/quickstart/

#### Step 7: Verify and iterate

Build all four images locally with `docker buildx build` to confirm the chain works. Then, against each image, run the runtime-verifiable commands below (each output line is what becomes the "as-of-build" anchor for the version-claims rule — no specific version is asserted in the Dockerfile, only here):

- **User identity**: `docker run --rm neolabhq/sandbox:latest id` — expect `uid=1000(vscode)`.
- **mise + languages** (Node, Python, Go, Java):
  ```bash
  docker run --rm neolabhq/sandbox:latest bash -lc \
    'mise --version && mise current && mise ls --global \
     && node --version && python3 --version && go version && java --version \
     && command -v node && command -v python3 && command -v go && command -v java'
  ```
  Expect every `command -v` to resolve under `/usr/local/share/mise/shims/`.
- **nix**: `docker run --rm neolabhq/sandbox:latest bash -lc 'nix --version && nix-env --version'`.
- **devbox**: `docker run --rm neolabhq/sandbox:latest bash -lc 'devbox version'`.
- **Top-up CLIs**: `docker run --rm neolabhq/sandbox:latest bash -lc 'gh --version && jq --version && brew --version && git --version'`.
- **Agents (in `:agents` and `:latest`)**: `claude --version`, `opencode --version`, `gemini --version`, `codex --version`, and (per the version-claims hedge) `command -v pi && pi --version || echo 'pi verification deferred — record resolved binary at implementation time'`, plus `[ -d /home/vscode/.oh-my-pi ] && echo oh-my-pi-present || echo oh-my-pi-verification-deferred`.
- **MCP / LSPs**: `codemap --help`, `gopls version`, `pyright --version`, `jdtls --help`, `typescript-language-server --version`, `docker mcp --help`.
- **`:universal` extras** — verify the languages added by `Dockerfile.universal` are present on top of `:latest`:
  ```bash
  docker run --rm neolabhq/sandbox:universal bash -lc \
    'ruby --version && rustc --version && cargo --version && zig version \
     && php --version && composer --version && dotnet --version \
     && g++ --version && javac --version'
  ```
  `g++` covers the C++ toolchain inherited from `Dockerfile.base` (`build-essential`) and `javac` confirms Java from `mise` (Step 1) is still on PATH — both must remain non-duplicated.
- **Final-layer wiring**: confirm `/home/vscode/.claude/settings.json` is populated after `configure-claude.sh` ran; statusline runs.
- **Entrypoint autodetection (Step 3)**: drive the new `entrypoint.sh` through both runtime detection and MCP-env-var gating:
  ```bash
  # (a) No project file, no MCP env vars — entrypoint logs both fall-through paths.
  docker run --rm neolabhq/sandbox:latest entrypoint-test bash -lc 'echo ok' 2>&1 \
    | grep -E 'No mise/devbox project file detected|No MCP env vars detected'

  # (b) mise.toml present in workdir — entrypoint runs `mise install` and execs under `mise exec --`.
  tmp=$(mktemp -d) && printf '[tools]\nnode = "lts"\n' > "$tmp/mise.toml"
  docker run --rm -v "$tmp:/workspaces/proj" -w /workspaces/proj neolabhq/sandbox:latest \
    bash -lc 'mise current | grep node'

  # (c) devbox.json present in workdir — entrypoint activates devbox shell.
  tmp=$(mktemp -d) && printf '{"packages":[]}\n' > "$tmp/devbox.json"
  docker run --rm -v "$tmp:/workspaces/proj" -w /workspaces/proj neolabhq/sandbox:latest \
    bash -lc 'devbox info >/dev/null && echo devbox-activated'

  # (d) MCP autodetection — Context7 is registered iff CONTEXT7_API_KEY is set.
  docker run --rm -e CONTEXT7_API_KEY=dummy neolabhq/sandbox:latest bash -lc \
    'claude mcp list | grep context7'
  ```
- **Ephemeral / single-shot flow**: run without `~/.claude*` mounts, only `CLAUDE_CODE_OAUTH_TOKEN`, confirm `claude --version` works.
- **Upstream sanity check** (for the Research Findings tables): `docker run --rm mcr.microsoft.com/devcontainers/base:trixie bash -lc 'cat /etc/os-release && id vscode && which git zsh && (which gh || echo no-gh) && (which node || echo no-node) && (which python3 || echo no-python)'`.
- **Devcontainer attach (local development only)**: rebuild this repo's devcontainer using the **preserved** `.devcontainer/devcontainer.json` and confirm VS Code attach still works. The `.devcontainer/` directory is intentionally not modified by this task; verifying it still functions is a regression check, not a step that requires changes.

---

### Technical Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Base image variant | `mcr.microsoft.com/devcontainers/base:trixie` (Debian 13 Trixie — current Debian stable line; verify GA status at build time per `/workspaces/sandbox/.claude/rules/research-version-claims.md`) | Debian trixie has a materially smaller footprint than Ubuntu derivatives and is `nix`/`devbox`-first-class on glibc-Linux. Ubuntu noble was considered (matches the previous `universal:6-noble`) but rejected because the size advantage and current-stable cadence of Debian trixie outweigh minor delta on apt source names. Alpine rejected because nix/devbox are poorly supported on musl. |
| Base-image pin strategy | Floating codename tag (`trixie`), NOT `@sha256:` digest | Microsoft's weekly CVE rebuilds flow in automatically. Reproducibility is preserved by digest-pinning our own `:base`/`:agents`/`:latest` downstream and by recording the resolved upstream digest as an OCI annotation per CI build. |
| Version manager stack | **`mise` + `nix` (single-user) + `devbox`**, all three installed | Three distinct roles: `mise` for language runtimes, `nix` for reproducible system CLIs, `devbox` as per-project nix wrapper. They compose without overlap when PATH is ordered shims → nix → apt → user-local. |
| Manager for `nvm`/`pyenv`/`sdkman`-style language pins | **`mise`**, NOT `nix`/`devbox` | `mise` is purpose-built to replace nvm/pyenv/goenv/sdkman with one CLI and one `mise.toml`. Shims-on-PATH works in non-interactive Docker shells without `mise activate`. First-class coverage of all four required languages. `nix`/`devbox` reserved for reproducible system CLIs where a `devbox.lock` (nixpkgs commit hash) provides bit-for-bit reproducibility. |
| Image-level additions | Apt top-up list (derived from `.devcontainer/Dockerfile` lines 7-58, adjusted for Debian trixie), `gh` CLI, Homebrew, mise + nix + devbox, AI agents (incl. `pi`/`oh-my-pi` hedged per the version-claims rule), MCP plugins, LSPs | Genuine gaps in `base:trixie` (which ships only git/zsh/oh-my-zsh). |
| Image layering | 4 separate Dockerfiles (`base` → `agents` → final → `universal`) | Required by task; independent rebuilds; smaller per-layer cache invalidation; `:universal` is the opt-in drop-in replacement for the legacy `devcontainers/universal` image. |
| `Dockerfile.universal` extra languages | Ruby/Rust/Zig via `mise`; PHP via apt; .NET via Microsoft's Debian apt repo; C++ via inherited `build-essential` from base; Java already in base (NOT duplicated) | Each language uses the manager with first-class support: mise for runtimes it covers cleanly, apt for those it doesn't (PHP build-from-source is slow), Microsoft's apt repo for .NET parity with `devcontainers/universal`. |
| `pi` / `oh-my-pi` install commands | Hedged — exact npm package name or installer URL deferred to implementation time and recorded in the CI build summary | Per `/workspaces/sandbox/.claude/rules/research-version-claims.md`; do not bake fabricated URLs into the Dockerfile. |
| Registry | `neolabhq/sandbox` | Required by task; lowercase per GHCR rules. Tags: `:base`, `:agents`, `:latest`, `:universal`, plus `:<variant>-<sha>`. |
| Multi-arch | `linux/amd64` + `linux/arm64` | Apple Silicon parity; matches existing `dpkg --print-architecture` logic. |
| Scripts location | Scripts remain at `.devcontainer/configure-claude.sh`, `.devcontainer/install-mcps.sh`, `.devcontainer/statusline.sh`; the final `Dockerfile` `COPY`s them into `/opt/devcontainer/` from `.devcontainer/` at build time. No `git mv`, no `sed -i` rewrite. | `.devcontainer/` is preserved unchanged per the row below; copying the scripts into the image at build time is non-destructive (the source files keep their `664/664/775` modes). The Dockerfile's `RUN chmod +x /opt/devcontainer/*.sh` sets the executable bit on the in-image copies only, so `/workspaces/sandbox/.claude/rules/preserve-permissions-on-move.md` is satisfied (the on-disk repo files are not touched). The scripts already use `$HOME` (no `/home/<user>/` hard-codes — verified at task-plan time via `grep -n 'HOME\|/home' .devcontainer/*.sh`), so they resolve correctly under the `vscode` user when run from `/opt/devcontainer/`. |
| `.devcontainer/` treatment | **Preserved unchanged** (no `devcontainer.json` edits, no `.devcontainer/Dockerfile` replacement, no script moves) | `.devcontainer/` is this repo's local development/testing environment and must remain functional with its current configuration. Downstream consumers who want a published-image devcontainer write their own `devcontainer.json` (see Step 6's "Using as a devcontainer" example). |
| Project autodetection at container start | **`/opt/devcontainer/entrypoint.sh`** wired as Dockerfile `ENTRYPOINT` in Step 3 | Walks up from `$PWD` for `devbox.json` → `mise.toml`/`.mise.toml`/`.tool-versions`, activates the matching project shell, and gates MCP registration on environment-variable presence (`CONTEXT7_API_KEY`, `DOCKER_MCP_SERVER`). Replaces the unconditional `postCreateCommand` invocation for published-image consumers; local `.devcontainer/` usage continues to call `install-mcps.sh` as `postCreateCommand` unchanged. |
| Non-root user | `vscode` (UID/GID 1000, default in `base:trixie`) | Use the image's existing user — UID-remapping to `node` or `codespace` is brittle (group reshuffling, home-dir ownership gymnastics, conflicts with `docker-outside-of-docker` feature's GID mapping). The preserved `.devcontainer/` scripts already use `$HOME` (verified via `grep -n 'HOME\|/home' .devcontainer/*.sh` at task-plan time), so no sed-rewrite is required and the scripts resolve correctly under the `vscode` user when copied into the published image. |
| nix install mode | Single-user (`--no-daemon`) | Docker containers have no systemd; daemon mode is unnecessary complexity. Single-user install owns `/nix/` as the `vscode` user; profile sourced from `/etc/profile.d/nix.sh`. |
| devbox scope | System-wide install (`/usr/local/bin/devbox`); NO image-level `devbox.json` | Devbox is exposed as a tool; downstream projects drop their own `devbox.json` at their repo root. Baking a global `devbox.json` would force every project to inherit unwanted packages. |
| `nvm`/`pyenv`/`sdkman` retention | NOT installed | Explicitly rejected — would re-introduce manager fragmentation that `mise` is meant to eliminate. Apps that need version pinning use `mise use`. |
| Pip-level helpers (`dvc`, `yq`) | `pip3 install --break-system-packages` against system Python | Debian trixie enforces PEP 668 the same way Ubuntu 24.04 does; `--break-system-packages` is the documented escape hatch and matches the prior project pattern. The "real" Python that devs use comes from `mise`, so polluting the system Python is acceptable. |
| MCP install timing | Runtime via two pathways: `/opt/devcontainer/entrypoint.sh` (Dockerfile `ENTRYPOINT`) for published-image consumers, and `postCreateCommand` -> `install-mcps.sh` for the local `.devcontainer/` flow | Both pathways gate on `CONTEXT7_API_KEY` / `DOCKER_MCP_SERVER` being present at runtime (these are not available at build time). The entrypoint runs unconditionally on every `docker run` (covering plain `docker run` and arbitrary devcontainer.json setups that consume `neolabhq/sandbox:*`), whereas `postCreateCommand` only fires inside a devcontainer lifecycle and is retained unchanged so the preserved `.devcontainer/` keeps working. See the "Project autodetection at container start" row above for the entrypoint's detection contract. |
| `docker-mcp` plugin | Baked into `Dockerfile.agents` | Deterministic build step; eliminates the brittle `bash-command` devcontainer feature. |
| Pipe-fed installers | `SHELL ["/bin/bash", "-o", "pipefail", "-c"]` declared in every Dockerfile (including `Dockerfile.universal`) | Per `/workspaces/sandbox/.claude/rules/dockerfile-curl-pipe-pipefail.md`; default dash shell does not support pipefail and silently produces empty-install layers on a partial curl. |

---

### File Structure

Files to **create**:
- `/workspaces/sandbox/Dockerfile.universal` — new image layered on top of the final `Dockerfile`, adding Ruby/PHP/.NET/Rust/Zig (Java is already in `Dockerfile.base` via mise; C++ is already in `Dockerfile.base` via `build-essential`); published as `neolabhq/sandbox:universal`.
- `/workspaces/sandbox/entrypoint.sh` — new repo-root shell script wired as the final `Dockerfile`'s `ENTRYPOINT`. Walks up from `$PWD` to detect `devbox.json` / `mise.toml` / `.mise.toml` / `.tool-versions` and activates the matching project shell, then conditionally registers MCP servers based on environment-variable presence (`CONTEXT7_API_KEY`, `DOCKER_MCP_SERVER`). See Step 3 for the full contract.

Files to **modify** (already present in the repo per `git ls-files` / `ls`):
- `/workspaces/sandbox/Dockerfile.base` — rewrite to use `FROM mcr.microsoft.com/devcontainers/base:trixie` and the Debian trixie apt top-up list.
- `/workspaces/sandbox/Dockerfile.agents` — rewrite to layer on `:base`, install AI agents (incl. `pi` / `oh-my-pi`, hedged), LSPs, and `docker-mcp`.
- `/workspaces/sandbox/Dockerfile` — rewrite to layer on `:agents`, `COPY` the three preserved scripts directly from `.devcontainer/` plus the new `entrypoint.sh` into `/opt/devcontainer/`, run `configure-claude.sh`, and wire `ENTRYPOINT` to the new script.
- `/workspaces/sandbox/.github/workflows/docker-publish.yml` — rewrite to publish all four image variants (`build-base` → `build-agents` → `build-final` → `build-universal`) with `lint` as a `needs:` dependency.
- `/workspaces/sandbox/README.md` — full usage documentation including the new mise + nix + devbox section, the `:universal` variant, and the entrypoint-driven autodetection (project files + MCP env vars).

Files to **leave untouched**:
- `/workspaces/sandbox/.devcontainer/devcontainer.json` — preserved as the local development/testing environment; downstream consumers write their own per Step 6's example.
- `/workspaces/sandbox/.devcontainer/Dockerfile` — same rationale; preserved unchanged.
- `/workspaces/sandbox/.devcontainer/configure-claude.sh` — preserved at its current path with current mode (664). The final `Dockerfile` `COPY`s it into `/opt/devcontainer/` at build time without modifying the on-disk source per `/workspaces/sandbox/.claude/rules/preserve-permissions-on-move.md`.
- `/workspaces/sandbox/.devcontainer/install-mcps.sh` — preserved at its current path with current mode (664). Continues to run as the local `devcontainer.json`'s `postCreateCommand`; the published image relies on `entrypoint.sh` for MCP registration instead.
- `/workspaces/sandbox/.devcontainer/statusline.sh` — preserved at its current path with current mode (775).
- `/workspaces/sandbox/.claude/`
- `/workspaces/sandbox/claude-helpers.sh`
- `/workspaces/sandbox/justfile`
- `/workspaces/sandbox/LICENSE`
- `/workspaces/sandbox/.specs/`

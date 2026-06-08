<p align="center">
  <img src="https://raw.githubusercontent.com/microsoft/fluentui-system-icons/78c9587b995299d5bfc007a0077773556ecb0994/assets/Cube/SVG/ic_fluent_cube_32_filled.svg" width="128px" alt="devcontainers organization logo" />
</p>

<div align="center">

<h1>Agent Sandbox</h1>

Development container for agents and people, that not allow agents to break your system.

[Quick Start](#quick-start) •
[Enviroment variables](#enviroment-variables) •
[Language Version Managment](#language-version-managment) •
[Using as a devcontainer](#using-as-a-devcontainer)
[Tools included](#tools-included) •

</div>

Development sandbox image based on official Microsoft's [devcontainers:base](https://github.com/devcontainers/images/tree/main) image. Focused on security and zero-configuration setup. Supports majority of languages and agents out of the box.

## Features

- Supported languages: Python, Node.js, Bun, C++, Java, C#, F#, .NET Core, PHP, Go
- Supported agents: Claude Code, OpenCode, Gemini CLI, Codex
- Multi-arch: `linux/amd64` + `linux/arm64` (Apple Silicon native).
- Language servers (LSP) preinstalled: TypeScript, Python, Java, Go
- MCP servers preinstalled: Context7, codemap, [docker-mcp](https://docs.docker.com/ai/mcp-catalog-and-toolkit/)
- Shells preinstalled: bash, fish, zsh (and Oh My Zsh!)
- Version/Package managers preinstalled: nvm, pyenv, rbenv, sdkman, conda, brew
- Enviroment managers: [mise](https://mise.jdx.dev), nix, [devbox](https://github.com/jetify-com/devbox)
- Majority of defult tools and packages that need for regular development: git, gh, jq, dvc, make, just, etc.
- All images validated using [Trivy Vulnarability Scanner](https://github.com/aquasecurity/trivy) and [Hadolint](https://github.com/hadolint/hadolint)

The base OS is Debian 13 (trixie). The non-root user inside the container is `vscode` (UID/GID 1000).


---

## Image variants and tags

Four images are published to the GitHub Container Registry under `neolabhq/sandbox`:

| Tag | Contents | Use when |
|-----|----------|----------|
| `neolabhq/sandbox:base` | `devcontainers/base:trixie` + mise (Node/Python/Go/Java) + nix + devbox + Homebrew + gh CLI + apt top-up list + dvc/yq | You need a clean multi-language base without agents |
| `neolabhq/sandbox:agents` | `:base` + Claude Code + OpenCode + Gemini CLI + Codex + codemap + gopls + pyright + jdtls + typescript-language-server + docker-mcp | You want agents and code-intelligence tools without Claude and MCP preconfiguration |
| `neolabhq/sandbox:latest` | `:agents` + pre-configured Claude Code settings + entrypoint autodetection | The default — everything wired up |
| `neolabhq/sandbox:universal` | `:latest` + Rust + Zig (via mise) + PHP + Composer (via apt/installer) + .NET SDK (via Microsoft Debian repo) | Drop-in replacement for `devcontainers/universal` with the broader language stack |

All four variants are published for `linux/amd64` and `linux/arm64`.

---

## Quick start

### Ephemeral / single-shot / CI

No `~/.claude*` mounts. Claude Code reads the OAuth token from `CLAUDE_CODE_OAUTH_TOKEN`, skips the interactive onboarding flow, and all state is discarded when the container exits.

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

Then launch your prefered agent

```bash
claude
```

Without `~/.claude*` mounts, every container starts cold: no command history, no plugin state, no previously registered MCPs. Claude Code authenticates via the token and runs without prompting for onboarding, but there is no continuity between runs. In exchange, you get a hermetic environment that cannot accidentally read or write your host's Claude configuration. This is the recommended pattern for CI and non-interactive contexts.

### Using devcontainer

Minimal configuration. Requires to use devcontainer cli or vscode built-in [devcontinaer](https://github.com/devcontainers/cli) integration. Devcontainer is pre-installed in VS Code/Claude/Antigravity/etc. 
The `docker-outside-of-docker` feature connects container agents to Docker on your host machine, allowing to start service or use testcontainers.

`.devcontainer/devcontainer.json`:

```jsonc
{
  "name": "Agent Sandbox",
  "image": "neolabhq/sandbox:latest",
  "features": {
    "ghcr.io/devcontainers/features/docker-outside-of-docker:1": {}
  },
  "remoteUser": "vscode",
  "remoteEnv": {
    "CLAUDE_CODE_OAUTH_TOKEN": "${localEnv:CLAUDE_CODE_OAUTH_TOKEN}",
    "ANTHROPIC_API_KEY": "${localEnv:ANTHROPIC_API_KEY}",
    "CONTEXT7_API_KEY": "${localEnv:CONTEXT7_API_KEY}"
  }
}
```

Launch devcontainer

```bash
devcontainer up --workspace-folder .
```

Check started container name and attach console to it
```bash
# List containers
docker ps
# Attach console to it
docker exec -it -u "vscode" -w "/workspace/$workspace_folder_name" "$container_id" bash
```

Then launch your prefered agent

```bash
claude
```

### Persistent Claude state

Mounts your host `~/.claude/` directory and `~/.claude.json` into the container so Claude Code's credentials, settings, command history, and MCP registrations survive across container restarts.

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

Then launch your prefered agent

```bash
claude
```

**What each flag does:**

| Flag | Purpose |
|------|---------|
| `-v "$HOME/.claude:/home/vscode/.claude"` | Persists Claude credentials, settings, plugins, and session state |
| `-v "$HOME/.claude.json:/home/vscode/.claude.json"` | Persists onboarding state, MCP registrations, and project history — prevents re-onboarding on every start |
| `-e CLAUDE_CODE_OAUTH_TOKEN` | Passes your OAuth token from the host environment; Claude Code skips the interactive login flow when this is set |
| `-e ANTHROPIC_API_KEY` | Alternative auth path to the OAuth token |
| `-e CONTEXT7_API_KEY` | When set, the entrypoint automatically registers the Context7 MCP server at container start |

**MCP registration.** The container's entrypoint reads `CONTEXT7_API_KEY` at startup. When the variable is non-empty, it registers the Context7 MCP server automatically. No manual `postCreateCommand` is required when consuming the published image directly. Set `DOCKER_MCP_SERVER` to a server identifier (e.g. `catalog://mcp/docker-mcp-catalog/paper-search`) to additionally register the baked docker-mcp profile pointing to that server.

**Prerequisite for `~/.claude.json`.** If the file does not exist on the host yet, create it before running the container — Docker will create a directory at that path otherwise, which Claude Code will reject:

```bash
touch ~/.claude.json
```

**Trade-off.** Mounting `~/.claude*` binds the container to your host machine's Claude profile. That is ideal for interactive daily development but undesirable for CI runners or shared environments. For those use cases, see the ephemeral pattern below.


---

## Volume mapping for projects

Mount your project directory under `/workspaces/` (the container's working directory):

```bash
-v "$PWD:/workspaces/$(basename "$PWD")"
-w "/workspaces/$(basename "$PWD")"
```

### Claude state (both files are needed for persistent mode)

```bash
-v "$HOME/.claude:/home/vscode/.claude"
-v "$HOME/.claude.json:/home/vscode/.claude.json"
```

`~/.claude/` contains credentials (`.credentials.json`), settings, statusline config, and session state.

`~/.claude.json` stores the onboarding completion flag (`hasCompletedOnboarding`), MCP server registrations, and project history. Without this file, Claude Code treats every container start as a first run and re-prompts for onboarding. Mount an empty file to suppress re-onboarding even if you do not need the history:

```bash
touch ~/.claude.json   # run once on the host if the file does not exist yet
```

### SSH keys and Git config (optional)

```bash
-v "$HOME/.ssh:/home/vscode/.ssh:ro"
-v "$HOME/.gitconfig:/home/vscode/.gitconfig:ro"
```

The `:ro` flag prevents the container from modifying your host keys or config.

---

## Mounting multiple project directories

Mount each project under a sibling path inside `/workspaces/`:

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

**How it works:**

- Each project is isolated in its own sub-directory. Agents and LSPs locate project roots by walking up to the nearest `.git`, `pyproject.toml`, `go.mod`, `package.json`, etc., so siblings do not bleed into each other.
- Cross-project work is enabled because all projects share one container `PATH`, one `gh` auth session, and one Claude session — useful for cross-repository refactors or when `shared-lib` is a dependency of multiple projects.
- For read-only dependencies, add `:ro` to that specific volume: `-v "$HOME/code/shared-lib:/workspaces/shared-lib:ro"`.

**Entrypoint autodetection across multiple projects.** The entrypoint walks up from the container's working directory (`$PWD`). When you `cd` into a project that contains a `devbox.json`, `mise.toml`, `.mise.toml`, or `.tool-versions`, the entrypoint will activate the matching project shell on the next container start (or on a `docker exec` invocation). See the [Language version manager stack](#language-version-manager-stack-mise--nix--devbox) section for details.

**Trade-off.** A single shared container is convenient but reduces isolation: a runaway process in one project can affect the others. For full isolation, run a separate container per project, each with its own `~/.claude*` mounts.

---

## Enviroment variables

### Passing CLAUDE_CODE_OAUTH_TOKEN

The primary authentication mechanism. When set, Claude Code skips the OAuth browser flow and uses the token directly.

Obtain a token on any machine where you are already logged in to Claude Code:

```bash
claude setup-token
```

Copy the printed token and store it in your shell environment (for example in `~/.bashrc` or `~/.zshrc`, or in a secrets manager):

```bash
export CLAUDE_CODE_OAUTH_TOKEN="sk-ant-..."
```

Pass it to the container with `-e CLAUDE_CODE_OAUTH_TOKEN` (no value needed on the right-hand side — Docker reads it from your current environment). Never hard-code the token value in a `docker run` command that may appear in shell history or logs.

### ANTHROPIC_API_KEY (alternative)

If you prefer API-key-based auth over OAuth, set `ANTHROPIC_API_KEY` instead. Claude Code accepts either. Pass it the same way:

```bash
-e ANTHROPIC_API_KEY
```

### CONTEXT7_API_KEY

When set, the container's entrypoint (`/opt/devcontainer/entrypoint.sh`) automatically registers the Context7 MCP server at container start:

```
claude mcp add --scope user --transport http context7 \
  https://mcp.context7.com/mcp \
  --header "CONTEXT7_API_KEY: <your-key>"
```

Obtain a key at [context7.com](https://context7.com). Without this key the entrypoint logs `"No MCP env vars detected; skipping MCP registration."` and continues — the rest of the image works normally.

### DOCKER_MCP_SERVER

When set to a Docker MCP catalog server identifier, the container's entrypoint (`/opt/devcontainer/entrypoint.sh`) automatically activates the baked docker-mcp CLI plugin at container start by running, in order:

```
docker mcp feature enable profiles
docker mcp catalog pull mcp/docker-mcp-catalog
docker mcp profile create --name dev-tools \
  --server "$DOCKER_MCP_SERVER" \
  --connect claude-code
```

Pass it the same way as the other secrets:

```bash
-e DOCKER_MCP_SERVER=catalog://mcp/docker-mcp-catalog/paper-search
```

The plugin binary is already installed in the image (`~/.docker/cli-plugins/docker-mcp`); this variable both gates whether the setup runs at startup and provides the server identifier that the `profile create` step binds the `dev-tools` profile to. Each command is best-effort: failures are logged with the `[entrypoint]` prefix and do not abort container startup. When this variable is unset the entrypoint logs `"No MCP env vars detected; skipping MCP registration."` (when `CONTEXT7_API_KEY` is also unset) and continues — the rest of the image works normally.

---

## Language Version Managment

The image ships three version management tools with distinct, non-overlapping roles.

### Tool roles

| Tool | Role | PATH position |
|------|------|---------------|
| `mise` | Language runtimes (Node, Python, Go, Java, Ruby, Rust, Zig) | `/usr/local/share/mise/shims` — first in PATH |
| `nix` | Reproducible system CLIs and libraries (pinned via nixpkgs commit) | `/home/vscode/.nix-profile/bin` |
| `devbox` | Per-project nix wrapper — consumes the same `/nix/store`; each repo provides its own `devbox.json` | exposes the project's nix profile on PATH when activated |

**Why three tools?** `mise` is purpose-built to replace `nvm`/`pyenv`/`goenv`/`sdkman` with a single CLI and a single `mise.toml`. Shim resolution works in non-interactive Docker shells without `mise activate`. `nix` owns reproducible system CLIs where a `devbox.lock` (nixpkgs commit hash) provides bit-for-bit reproducibility. `devbox` is exposed for per-project use; no image-wide `devbox.json` is shipped.

**What is NOT installed:** `nvm`, `pyenv`, `sdkman`, `rvm`, `rbenv` — these would re-introduce the manager fragmentation that `mise` is meant to eliminate. Use `mise` for all language version pinning.

### Image-global language defaults

The image-level defaults (set via `mise use --global`) resolve at build time. Exact resolved versions are recorded in the CI build summary; they are not pinned in the Dockerfile. 

### Language runtime autodetection

The image wires `/opt/devcontainer/entrypoint.sh` as the Dockerfile `ENTRYPOINT`. The entrypoint runs as the `vscode` user before the user's shell or command starts. 

It automatically detects following:

- Project runtimes is based on the presence of `mise.toml` / `.mise.toml` / `.tool-versions` / `devbox.json`. If any of the files present, it will invoke mise or devbox cli to install runtimes and innject in shell. Mise invoked first. If not files present, it fallbacks to latest versions.
- MCP based on the presence of the listed environment variables.

#### Example project files

Override language versions for a specific project by dropping a `mise.toml` at the project root:

```toml
# mise.toml at the project root
[tools]
node = "20.11.0"
python = "3.12"
go = "1.22"

[env]
NODE_OPTIONS = "--max-old-space-size=4096"
```

Override system-level CLIs for a specific project by dropping a `devbox.json` at the project root:

```json
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

**(e) Role boundary.** `mise` owns language runtimes in the project file just as it does at the image level: Node, Python, Go, Java, Ruby, Deno, Bun, etc. `devbox` owns system CLIs and libraries a project pins via nixpkgs. They compose cleanly because devbox's nix profile entries land on PATH before the mise shims when `devbox shell` activates, but the mise shims still resolve language binaries because devbox does not install Node, Python, Go, or Java by default.


---

## Using as a devcontainer

This section describes how to consume the published image as a devcontainer base in your own project. It is not a description of changes to this repo's `.devcontainer/` directory (which is preserved for local development of the sandbox itself).

### Quick setup

Minimal configuration. The `docker-outside-of-docker` feature connects container agents to Docker on your host machine.

`.devcontainer/devcontainer.json`:

```jsonc
{
  "name": "Agent Sandbox",
  "image": "neolabhq/sandbox:latest",
  "features": {
    "ghcr.io/devcontainers/features/docker-outside-of-docker:1": {}
  },
  "remoteUser": "vscode",
  "remoteEnv": {
    "CLAUDE_CODE_OAUTH_TOKEN": "${localEnv:CLAUDE_CODE_OAUTH_TOKEN}",
    "ANTHROPIC_API_KEY": "${localEnv:ANTHROPIC_API_KEY}",
    "CONTEXT7_API_KEY": "${localEnv:CONTEXT7_API_KEY}"
  }
}
```

### Setup with Docker MCP

For projects that want MCP servers proxied from the host's [Docker MCP Catalog](https://docs.docker.com/ai/mcp-catalog-and-toolkit/), extend the quick-setup example with an explicit MCP catalog mount and the `DOCKER_MCP_SERVER` variable:

`.devcontainer/devcontainer.json`:

```jsonc
{
  "name": "Agent Sandbox",
  "image": "neolabhq/sandbox:latest",
  "features": {
    "ghcr.io/devcontainers/features/docker-outside-of-docker:1": {}
  },
  "mounts": [
    "source=${localEnv:HOME}/.docker/mcp,target=/home/vscode/.docker/mcp,type=bind,consistency=cached"
  ],
  "remoteUser": "vscode",
  "remoteEnv": {
    "CLAUDE_CODE_OAUTH_TOKEN": "${localEnv:CLAUDE_CODE_OAUTH_TOKEN}",
    "CONTEXT7_API_KEY": "${localEnv:CONTEXT7_API_KEY}",
    "DOCKER_MCP_SERVER": "catalog://mcp/docker-mcp-catalog/paper-search"
  }
}
```


---

## Immutable rollback tags

Every CI run also publishes SHA-suffixed immutable tags alongside the moving ones:

```
neolabhq/sandbox:base-<sha>
neolabhq/sandbox:agents-<sha>
neolabhq/sandbox:latest-<sha>
neolabhq/sandbox:universal-<sha>
```

These tags are never overwritten. If a moving tag regresses — whether from a change in this repo or an upstream Microsoft rebuild flowing through the floating `base:trixie` pin — restore service by re-tagging the last known-good SHA variant back to the moving tag:

```bash
docker buildx imagetools create \
  -t neolabhq/sandbox:latest \
  neolabhq/sandbox:latest-<previous-good-sha>
```

This operation is atomic at the registry level and requires no rebuild. The same pattern applies to `:base`, `:agents`, and `:universal`.

For an upstream Microsoft regression (the floating `base:trixie` tag rebuilt with a bad layer), the `build-base` CI job records the resolved upstream digest as an OCI annotation on `:base`. Emergency-pin `Dockerfile.base` to `mcr.microsoft.com/devcontainers/base:trixie@sha256:<last-good>` recorded there, then revert to the floating tag once upstream stabilizes.

---

## Tools included

### Languages

Language runtimes are managed by [`mise`](https://mise.jdx.dev) — a single Rust-based meta version manager that replaces `nvm`, `pyenv`, `goenv`, and `sdkman` with one CLI and one `mise.toml`. The `mise` shims directory is prepended to `PATH` so `node`, `python3`, `go`, and `java` resolve through `mise` first in any shell (interactive, non-interactive, `docker exec`, CI) without requiring `mise activate`.

| Image | Language | Manager | Default selector |
|-------|----------|---------|-----------------|
| `:base` and above | Node.js | `mise` | `node@lts` — current Node LTS at build time |
| `:base` and above | Python | `mise` | `python@latest` — current stable Python 3 at build time |
| `:base` and above | Go | `mise` | `go@latest` — current stable Go at build time |
| `:base` and above | Java | `mise` | `java@temurin-lts` — current Eclipse Temurin LTS at build time |
| `:universal` only | Ruby | `mise` | `ruby@latest` — current stable Ruby at build time |
| `:universal` only | Rust | `mise` | `rust@latest` — current stable Rust at build time |
| `:universal` only | Zig | `mise` | `zig@latest` — current stable Zig at build time |
| `:universal` only | PHP | apt | Current stable PHP from Debian trixie's archive |
| `:universal` only | .NET SDK | Microsoft apt repo | Current LTS .NET SDK; verify at build time |

The exact resolved versions depend on when the image was built. To inspect them:

```bash
docker run --rm neolabhq/sandbox:latest bash -lc \
  'mise current && node --version && python3 --version && go version && java --version'

# For :universal extras
docker run --rm neolabhq/sandbox:universal bash -lc \
  'ruby --version && rustc --version && cargo --version && zig version \
   && php --version && composer --version && dotnet --version'
```

### Version managers

| Tool | Purpose | Verify |
|------|---------|--------|
| `mise` | Language runtime version manager | `mise --version && mise current` |
| `nix` | Reproducible system CLI package manager | `nix --version && nix-env --version` |
| `devbox` | Per-project nix wrapper | `devbox version` |
| Homebrew (Linuxbrew) | Cross-cutting CLI tooling | `brew --version` |

### AI coding agents

| Agent | Command | Installed via |
|-------|---------|---------------|
| Claude Code | `claude` | Official `claude.ai/install.sh` installer |
| OpenCode | `opencode` | Official `opencode.ai/install` installer |
| Gemini CLI | `gemini` | `npm install -g @google/gemini-cli` (requires Node LTS) |
| Codex (OpenAI) | `codex` | `npm install -g @openai/codex` |

`pi` and `oh-my-pi` are planned additions. Install commands are deferred until upstream project sources are verified; the spec's CI build summary records their status.

### MCP servers

| Server | Transport | Registration |
|--------|-----------|-------------|
| Context7 | HTTP (`https://mcp.context7.com/mcp`) | Registered at container start by the entrypoint when `CONTEXT7_API_KEY` is set |
| codemap | Stdio (binary at `/usr/local/bin/codemap`) | Baked into `:agents`; feeds project structure context to agents |
| docker-mcp | CLI plugin (`~/.docker/cli-plugins/docker-mcp`) | Baked into `:agents`; activated at container start by the entrypoint when `DOCKER_MCP_SERVER` is set to a server identifier (e.g. `catalog://mcp/docker-mcp-catalog/paper-search`) |

### Language servers (LSPs)

| LSP | Language | Command | Verify |
|-----|----------|---------|--------|
| gopls | Go | `gopls` | `gopls version` |
| pyright | Python | `pyright` | `pyright --version` |
| jdtls (Eclipse JDT) | Java | `jdtls` | `jdtls --help` |
| typescript-language-server | TypeScript / JavaScript | `typescript-language-server` | `typescript-language-server --version` |

### Other tools

| Tool | Purpose |
|------|---------|
| `gh` | GitHub CLI |
| `jq` | JSON processor |
| `dvc` | Data version control |
| `yq` | YAML / JSON processor |
| `bun` | Alternative JS runtime and package manager |
| `just` (`rust-just`) | Task runner |
| `git` | Version control |
| `build-essential` | C/C++ compiler toolchain (`gcc`, `g++`, `make`) |


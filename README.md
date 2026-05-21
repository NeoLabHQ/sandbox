# NeoLabHQ Sandbox

A multi-architecture development sandbox image built on top of Microsoft's `devcontainers/universal:6-noble` base. Ships four AI coding agents, a full suite of language servers, MCP servers, and a `mise`-managed language toolchain out of the box — ready to use with `docker run` or as a devcontainer.

Multi-arch: `linux/amd64` + `linux/arm64` (Apple Silicon native).

---

## Table of Contents

1. [Image variants and tags](#image-variants-and-tags)
2. [Quick start — persistent Claude state (recommended for daily dev)](#quick-start--persistent-claude-state-recommended-for-daily-dev)
3. [Quick start — ephemeral / single-shot / CI](#quick-start--ephemeral--single-shot--ci)
4. [Volume mapping for projects](#volume-mapping-for-projects)
5. [Mounting multiple project directories](#mounting-multiple-project-directories)
6. [Authentication — tokens and API keys](#authentication--tokens-and-api-keys)
7. [Using as a devcontainer](#using-as-a-devcontainer)
8. [Tools included](#tools-included)
9. [Building locally](#building-locally)

---

## Image variants and tags

Three images are published to the GitHub Container Registry under `ghcr.io/neolabhq/sandbox`:

| Tag | Contents | Use when |
|-----|----------|----------|
| `:base` | `universal:6-noble` + `mise` (Node/Python/Go/Java) + Homebrew + `dvc`/`yq` | You only need a clean multi-language base |
| `:agents` | `:base` + Claude Code + OpenCode + Gemini CLI + Codex + LSPs + codemap + docker-mcp | You want agents and code-intelligence tools without the Claude config |
| `:latest` | `:agents` + `configure-claude.sh` pre-run + scripts at `/opt/devcontainer/` | The default — everything wired up |

All three variants are published for `linux/amd64` and `linux/arm64`.

### Immutable rollback tags

Every CI run also publishes SHA-suffixed immutable tags alongside the moving ones:

```
ghcr.io/neolabhq/sandbox:base-<sha>
ghcr.io/neolabhq/sandbox:agents-<sha>
ghcr.io/neolabhq/sandbox:latest-<sha>
```

These exist specifically for rollback. If a moving tag regresses (whether from a change in this repo or an upstream Microsoft rebuild flowing through the floating `universal:6-noble` pin), re-tag the last known-good SHA variant back to the moving tag:

```bash
docker buildx imagetools create \
  -t ghcr.io/neolabhq/sandbox:latest \
  ghcr.io/neolabhq/sandbox:latest-<previous-good-sha>
```

On tag pushes (`v*`), semver-tagged variants (e.g. `v1.2.3`) are also published.

---

## Quick start — persistent Claude state (recommended for daily dev)

Mounts your host `~/.claude/` directory and `~/.claude.json` into the container so Claude Code's credentials, settings, command history, and MCP registrations survive across container restarts.

```bash
docker run -it --rm \
  -v "$PWD:/workspaces/$(basename "$PWD")" \
  -v "$HOME/.claude:/home/codespace/.claude" \
  -v "$HOME/.claude.json:/home/codespace/.claude.json" \
  -e CLAUDE_CODE_OAUTH_TOKEN \
  -e ANTHROPIC_API_KEY \
  -e CONTEXT7_API_KEY \
  -w "/workspaces/$(basename "$PWD")" \
  ghcr.io/neolabhq/sandbox:latest \
  bash
```

**What each flag does:**

| Flag | Purpose |
|------|---------|
| `-v "$HOME/.claude:/home/codespace/.claude"` | Persists Claude credentials, settings, plugins, and session state |
| `-v "$HOME/.claude.json:/home/codespace/.claude.json"` | Persists onboarding state, MCP registrations, and project history — prevents re-onboarding on every start |
| `-e CLAUDE_CODE_OAUTH_TOKEN` | Passes your OAuth token from the host environment; Claude Code skips the interactive login flow when this is set |
| `-e ANTHROPIC_API_KEY` | Passes your Anthropic API key (alternative auth path to OAUTH token) |
| `-e CONTEXT7_API_KEY` | Required by `install-mcps.sh` to register the Context7 MCP server at container start |

**Trade-off.** Mounting `~/.claude*` binds the container to your host machine's Claude profile. That is ideal for interactive daily development but undesirable for CI runners or shared environments where you want each container to start with a clean slate. For those use cases, see the ephemeral pattern below.

If `~/.claude.json` does not exist on the host yet, create it first: `touch ~/.claude.json`. Docker will create a directory at that path otherwise, which Claude Code will reject.

---

## Quick start — ephemeral / single-shot / CI

No `~/.claude*` mounts. Claude Code reads the OAuth token from `CLAUDE_CODE_OAUTH_TOKEN`, skips the interactive onboarding flow, and all state is discarded when the container exits. Suitable for CI runners, one-off remote agent jobs, and disposable PR review sandboxes.

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

**Trade-off.** Without `~/.claude*` mounts, every container starts cold: no command history, no plugin state, no previously registered MCPs. Claude Code authenticates via the token and runs without prompting for onboarding, but there is no continuity between runs. In exchange, you get a hermetic environment that cannot accidentally read or write your host's Claude configuration. This is the recommended pattern for CI / non-interactive contexts.

---

## Volume mapping for projects

Mount your project directory under `/workspaces/` (the container's working directory):

```bash
-v "$PWD:/workspaces/$(basename "$PWD")"
-w "/workspaces/$(basename "$PWD")"
```

### Claude state (both files are needed)

```bash
-v "$HOME/.claude:/home/codespace/.claude"
-v "$HOME/.claude.json:/home/codespace/.claude.json"
```

`~/.claude/` contains credentials (`.credentials.json`), settings, statusline config, plugins, and session state.

`~/.claude.json` stores the onboarding completion flag (`hasCompletedOnboarding`), MCP server registrations, and project history. Without this file, Claude Code treats every container start as a first run and re-prompts for onboarding. Even if you do not need the history, mount an empty file to suppress re-onboarding:

```bash
touch ~/.claude.json  # run once on the host if the file does not exist yet
```

### SSH keys and Git config (optional)

```bash
-v "$HOME/.ssh:/home/codespace/.ssh:ro"
-v "$HOME/.gitconfig:/home/codespace/.gitconfig:ro"
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
  -v "$HOME/.claude:/home/codespace/.claude" \
  -v "$HOME/.claude.json:/home/codespace/.claude.json" \
  -e CLAUDE_CODE_OAUTH_TOKEN \
  -w "/workspaces" \
  ghcr.io/neolabhq/sandbox:latest \
  bash
```

**How it works:**

- Each project is isolated at its own sub-directory. Agents and LSPs locate project roots by walking up to the nearest `.git`, `pyproject.toml`, `go.mod`, `package.json`, etc., so siblings do not bleed into each other.
- Cross-project work is enabled because all projects share one container `PATH`, one `gh` auth session, and one Claude session — useful for cross-repository refactors or when `shared-lib` is a dependency of both `project-a` and `project-b`.
- For read-only dependencies (e.g., a vendored monorepo sub-tree you want to reference but not modify), add `:ro` to that specific volume:

  ```bash
  -v "$HOME/code/shared-lib:/workspaces/shared-lib:ro"
  ```

**Trade-off.** A single shared container is convenient but reduces isolation: a runaway process in one project can affect the others. For full isolation run a separate container per project, each with its own `~/.claude*` mounts.

---

## Authentication — tokens and API keys

### `CLAUDE_CODE_OAUTH_TOKEN` (recommended)

The primary authentication mechanism for non-interactive use. When set, Claude Code skips the OAuth browser flow and uses the token directly.

Obtain a token on any machine where you are already logged in:

```bash
claude setup-token
```

Copy the printed token and store it in your shell environment (e.g. in `~/.bashrc` or `~/.zshrc`, or in a secrets manager):

```bash
export CLAUDE_CODE_OAUTH_TOKEN="sk-ant-..."
```

Pass it to the container with `-e CLAUDE_CODE_OAUTH_TOKEN` (no value needed on the right-hand side — Docker reads it from your current environment).

### `ANTHROPIC_API_KEY` (alternative)

If you prefer API-key-based auth over OAuth, set `ANTHROPIC_API_KEY` instead. Claude Code accepts either. Pass it the same way:

```bash
-e ANTHROPIC_API_KEY
```

### `CONTEXT7_API_KEY`

Required by `/opt/devcontainer/install-mcps.sh` (run at `postCreateCommand` time in devcontainer mode, or manually in standalone `docker run` mode) to register the Context7 MCP server. Obtain a key at [context7.com](https://context7.com).

```bash
-e CONTEXT7_API_KEY
```

Without this key, `install-mcps.sh` will skip or fail the Context7 registration step. The rest of the image continues to work.

---

## Using as a devcontainer

The devcontainer spec lets you declare the image, features, and environment variables in a `.devcontainer/devcontainer.json` file. VS Code and GitHub Codespaces both consume this format.

### Quick setup

Minimal configuration. The `docker-outside-of-docker` feature must remain a devcontainer feature (not baked into the image) because it depends on the host Docker socket path and group GID mapping that only the devcontainer CLI or VS Code can wire up.

`.devcontainer/devcontainer.json`:

```jsonc
{
  "name": "NeoLabHQ Sandbox",
  "image": "ghcr.io/neolabhq/sandbox:latest",
  "features": {
    "ghcr.io/devcontainers/features/docker-outside-of-docker:1": {}
  },
  "remoteUser": "codespace",
  "remoteEnv": {
    "CLAUDE_CODE_OAUTH_TOKEN": "${localEnv:CLAUDE_CODE_OAUTH_TOKEN}",
    "ANTHROPIC_API_KEY": "${localEnv:ANTHROPIC_API_KEY}",
    "CONTEXT7_API_KEY": "${localEnv:CONTEXT7_API_KEY}"
  },
  "postCreateCommand": "/opt/devcontainer/install-mcps.sh"
}
```

`postCreateCommand` runs `/opt/devcontainer/install-mcps.sh` once after the container is created. This script registers the Context7 MCP server using the `CONTEXT7_API_KEY` passed via `remoteEnv`.

### Setup with Docker MCP

For projects that want MCP servers proxied from the host's [Docker MCP Catalog](https://docs.docker.com/ai/mcp-catalog-and-toolkit/) (managed via Docker Desktop's MCP Toolkit and the [`docker/mcp-gateway`](https://github.com/docker/mcp-gateway) CLI plugin), extend the quick-setup example with an explicit `docker-mcp` mount and runtime hook.

The `docker-mcp` plugin is already baked into the image (installed in `Dockerfile.agents`). The devcontainer only needs to mount the host MCP catalog directory and forward the MCP gateway socket:

`.devcontainer/devcontainer.json`:

```jsonc
{
  "name": "NeoLabHQ Sandbox (Docker MCP)",
  "image": "ghcr.io/neolabhq/sandbox:latest",
  "features": {
    "ghcr.io/devcontainers/features/docker-outside-of-docker:1": {}
  },
  "mounts": [
    "source=${localEnv:HOME}/.docker/mcp,target=/home/codespace/.docker/mcp,type=bind,consistency=cached"
  ],
  "remoteUser": "codespace",
  "remoteEnv": {
    "CLAUDE_CODE_OAUTH_TOKEN": "${localEnv:CLAUDE_CODE_OAUTH_TOKEN}",
    "DOCKER_MCP_CATALOG_DIR": "/home/codespace/.docker/mcp"
  },
  "postCreateCommand": "docker mcp gateway run --help >/dev/null && /opt/devcontainer/install-mcps.sh"
}
```

**Related resources:**

- [Docker MCP Catalog and Toolkit overview](https://docs.docker.com/ai/mcp-catalog-and-toolkit/)
- [`docker/mcp-gateway` source](https://github.com/docker/mcp-gateway) — the CLI plugin baked into this image
- [Model Context Protocol specification](https://modelcontextprotocol.io/introduction)

---

## Tools included

### Languages

Languages are managed by [`mise`](https://mise.jdx.dev) — a single Rust-based meta version manager that provides a unified CLI and a single `mise.toml` source of truth for default versions. The `mise` shims directory is prepended to `PATH` so `node`, `python`, `go`, `java`, and `javac` resolve through `mise` first in any shell (interactive, non-interactive, `docker exec`, CI).

| Language | Managed by | Default selector |
|----------|-----------|-----------------|
| Node.js | `mise` | `node@lts` — resolves to the current Node LTS at build time |
| Python | `mise` | `python@latest` — resolves to the current Python stable at build time |
| Go | `mise` | `go@latest` — resolves to the current Go stable at build time |
| Java | `mise` | `java@temurin-lts` — resolves to the current Eclipse Temurin LTS at build time |
| Ruby | `rvm` (from `universal:6-noble`) | Recent stable line(s) from the base image |
| PHP | Provided by `universal:6-noble` | Recent stable line from the base image |
| .NET | Provided by `universal:6-noble` | Recent stable line from the base image |

The exact resolved versions of the four `mise`-managed languages depend on when the image was built. To inspect them in a running container:

```bash
# Show all mise-managed tools and their active versions
mise current

# Or verify individual binaries
node --version && python --version && go version && java --version
```

To pin a project to specific versions, add a `mise.toml` at the repo root:

```toml
[tools]
node = "lts"
python = "3.12"
go = "1.22"
java = "temurin-21"
```

The base image's per-language managers (`nvm`, SDKMAN, `rvm`, the `/usr/local/python` layout, the `/usr/local/go` install) are left in place and remain reachable. `mise` sits above them via PATH ordering and falls through for languages it does not manage.

### Package managers and utilities

| Tool | Purpose |
|------|---------|
| Homebrew (Linuxbrew) | Cross-cutting CLI tooling; install packages with `brew install` |
| npm / npx | Bundled with the `mise`-managed Node |
| pip | Bundled with the `mise`-managed Python; `dvc` and `yq` pre-installed |
| `gh` (GitHub CLI) | Pre-installed in `universal:6-noble` |

### AI coding agents

| Agent | Command | Notes |
|-------|---------|-------|
| Claude Code | `claude` | Installed via the official `claude.ai/install.sh` installer |
| OpenCode | `opencode` | Installed via the official `opencode.ai/install` installer |
| Gemini CLI | `gemini` | Installed via `npm install -g @google/gemini-cli` |
| Codex (OpenAI) | `codex` | Installed via `npm install -g @openai/codex` |

### MCP servers

| Server | Transport | Registration |
|--------|-----------|-------------|
| Context7 | HTTP (`https://mcp.context7.com/mcp`) | Registered at container start by `install-mcps.sh` (requires `CONTEXT7_API_KEY`) |
| codemap | Stdio (binary at `/usr/local/bin/codemap`) | Baked into `:agents`; feeds project structure context to agents |
| docker-mcp | CLI plugin (`~/.docker/cli-plugins/docker-mcp`) | Baked into `:agents`; proxies MCP servers from the host Docker MCP catalog |

For more on the Model Context Protocol, see [modelcontextprotocol.io/introduction](https://modelcontextprotocol.io/introduction).

### Language servers (LSPs)

| LSP | Language | Command |
|-----|----------|---------|
| gopls | Go | `gopls` |
| pyright | Python | `pyright` |
| jdtls (Eclipse JDT) | Java | `jdtls` |
| typescript-language-server | TypeScript / JavaScript | `typescript-language-server` |

### Other tools

- `dvc` — data version control
- `yq` — YAML / JSON processor
- `bun` — alternative JS runtime and package manager
- `just` (`rust-just`) — task runner

---

## Building locally

The image chain is `Dockerfile.base` → `Dockerfile.agents` → `Dockerfile`. Each layer must be built before the next can reference it.

```bash
# 1. Build the base image
docker build -f Dockerfile.base -t ghcr.io/neolabhq/sandbox:base .

# 2. Build the agents image (references :base by default via ARG)
docker build -f Dockerfile.agents -t ghcr.io/neolabhq/sandbox:agents .

# 3. Build the final image (references :agents by default via ARG)
docker build -f Dockerfile -t ghcr.io/neolabhq/sandbox:latest .
```

To pass a custom base image (e.g., a locally-built variant):

```bash
docker build -f Dockerfile.agents \
  --build-arg BASE_IMAGE=ghcr.io/neolabhq/sandbox:base \
  -t ghcr.io/neolabhq/sandbox:agents .

docker build -f Dockerfile \
  --build-arg AGENTS_IMAGE=ghcr.io/neolabhq/sandbox:agents \
  -t ghcr.io/neolabhq/sandbox:latest .
```

For multi-arch builds (requires `docker buildx`):

```bash
docker buildx build --platform linux/amd64,linux/arm64 \
  -f Dockerfile.base \
  -t ghcr.io/neolabhq/sandbox:base \
  --push .
```

The CI workflow (`.github/workflows/docker-publish.yml`) runs vulnerability scanning with Trivy before pushing any image. When building locally, you can run a quick scan with:

```bash
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy:latest image ghcr.io/neolabhq/sandbox:latest
```

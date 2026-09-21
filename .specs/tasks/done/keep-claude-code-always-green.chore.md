---
title: Add shared-volume Claude install and cache-free weekly rebuilds to keep Claude Code and marketplace green
---

## Initial User Prompt

this project have issue. Claude code becomes outdated quite fast, so it need to be updated regular. Which means every time starting container need to write `claude update && claude` when entering container. Possible to add update as start command in devcontainer, but it will slowdown container launch. then this container need to be periodically updated, to keep base claude code version safe. But I not see good way to implement it. Plus also need update context-enginering-kit plugin marketplace, together with claude code, as it also quite often updated. Suggest options to reach desired state: close to allways green claude code and marketplace.
Options that I named have minuses, but still considered, if you not suggest something better.

### Requirements

#### Context and findings

Observed live in a running `neolabhq/sandbox:latest` container on 2026-09-20 (verify at build time with `claude --version` and `ls ~/.local/share/claude/versions`):

- Claude Code's native background updater already works. The image was built with one version baked in and the container had self-updated to a newer one; `~/.local/bin/claude` had been re-pointed by the updater. Stale-binary-on-first-launch is therefore **accepted as-is** and explicitly out of scope.
- `~/.local/share/claude/` contains **only** `versions/<semver>` binaries (~230 MB each, two present = 446 MB). No config, no credentials, no sessions.
- `~/.claude/plugins/` holds `marketplaces/` (~40 MB), `cache/` (~3.8 MB), `installed_plugins.json`, `known_marketplaces.json`, `plugin-catalog-cache.json` (~516 KB) — ~45 MB total.
- `.github/workflows/publish.yaml` triggers only on `push` to `master`. There is no scheduled rebuild, so the published moving tags accumulate an ever-older baked Claude Code and marketplace clone.
- All eight `docker/build-push-action` steps in `publish.yaml` use `cache-from: type=gha` / `cache-to: type=gha`.

#### Scope

Three changes. The default (no-volume) behaviour of every documented usage pattern must remain byte-for-byte identical to today.

**1. `.github/workflows/publish.yaml` — cache-free scheduled and push builds**

- Add a weekly `schedule:` trigger (`cron: '0 3 * * 1'`, Mondays 03:00 UTC) alongside the existing `push`. The repo default branch is `master`, which matches the existing `push.branches`, so GitHub's default-branch-only rule for `schedule:` is satisfied.
- Remove **all** GHA build cache: delete the 16 `cache-from` / `cache-to` lines across the eight build steps, and add an explicit `no-cache: true` with a comment stating the intent (every build must re-resolve upstream dependencies — `claude.ai/install.sh`, marketplace clones, apt, mise, brew, nix). The comment exists so a future contributor does not reintroduce caching as an "optimization"; with cache enabled a scheduled rebuild on an unchanged commit would reuse every layer and republish a byte-identical stale image, making the cron pointless.
- Add `paths-ignore` to the `push` trigger for docs-only paths (`README.md`, `CONTRIBUTING.md`, `LICENSE`, `.specs/**`, `.claude/**`) so a documentation commit does not trigger a full cold build of the four-image chain. The weekly cron rebuilds regardless, so skipping docs commits cannot make the published image stale.
- Trivy scanning and the SHA-suffixed immutable rollback tags already run per build, so weekly CVE re-scanning of the moving tags comes for free.

**2. `setup.sh` — repair a dangling `claude` symlink**

`~/.local/bin/claude` is a symlink to a specific version directory and lives **outside** the runtime volume. Docker seeds a named volume only when it is empty and never re-seeds a populated one. So once a user has the runtime volume configured, the first `docker pull` of a newer image leaves the image's symlink pointing at a version that the volume does not contain, and `claude` fails with "No such file or directory". The weekly cron makes this fire on a weekly cadence for every user with the volume configured — it is the normal path, not an edge case.

Add a repair step to the existing per-container section of `setup.sh`: if `~/.local/bin/claude` does not resolve, re-point it at the highest `sort -V` entry under `~/.local/share/claude/versions`. `[ ! -e ]` is false for a dangling symlink, so the step fires exactly when broken and is a no-op otherwise. It must honour `setup.sh`'s existing contracts — always exit 0, log to stderr with the `[sandbox-setup]` prefix, never `exec`. It cooperates with Claude Code's own updater, which re-points the same symlink on its next update.

**3. `README.md` — document the shared-install variant**

Each usage example (ephemeral/CI, devcontainer quick setup, devcontainer with Docker MCP, persistent Claude state, multiple project directories) gains an **optional** shared-install variant adding two named volumes:

```
-v sandbox-claude-runtime:/home/vscode/.local/share/claude
-v sandbox-claude-plugins:/home/vscode/.claude/plugins
```

and the devcontainer equivalent:

```jsonc
"mounts": [
  "source=sandbox-claude-runtime,target=/home/vscode/.local/share/claude,type=volume",
  "source=sandbox-claude-plugins,target=/home/vscode/.claude/plugins,type=volume"
]
```

Document explicitly:

- These volumes hold **binaries and marketplace clones only** — no credentials, no sessions, no project history. Mounting them does not leak the host Claude profile, so they are safe in the ephemeral/CI pattern.
- One Claude Code install per machine, shared by every sandbox container. A marketplace updated once by hand applies everywhere.
- In persistent mode the `~/.claude/plugins` named volume is nested inside the `~/.claude` host bind mount. Docker resolves by path depth so this works, but the host's `plugins/` directory is shadowed — plugin state becomes machine-shared rather than host-profile-bound.
- To pick up plugins newly added to `configure-claude.sh`, run `docker volume rm sandbox-claude-plugins`. Docker seeds a volume only once, so an already-populated volume will not gain them otherwise.
- The image keeps its baked Claude Code binary as a **seed floor**: with no volume configured the container behaves exactly as today, and with a volume configured Docker auto-seeds it on first use.

#### Explicitly out of scope (considered and rejected during brainstorming)

Do not reintroduce these without a new decision:

- **Any install or "ensure-latest" step at container start.** The seeded volume already has a binary and Claude Code self-updates. An install step is redundant and would slow container launch, which is the cost the user set out to avoid.
- **Strict install-on-first-use with no baked binary.** Rejected because it makes the no-mount ephemeral/CI pattern pay a ~230 MB download per run and hard-require network.
- **Re-applying `autoUpdate: true` to `known_marketplaces.json` at runtime.** Claude Code rewrites that file and drops the key. With a shared marketplace volume the user updates the marketplace once by hand and it applies everywhere, so the flag is unnecessary. The existing build-time jq patch in `configure-claude.sh` is therefore dead weight but is left untouched by this task.
- **A console banner announcing the shared install.** Rejected — it would describe behaviour the script no longer performs.
- **Pruning `~/.local/share/claude/versions`.** Claude Code runs this layout on every machine and is assumed to manage its own version retention.
- **`VOLUME` in the Dockerfile.** Yields an anonymous per-container volume, not the machine-wide shared install, and litters `docker volume ls`.
- **A background/detached updater, a pre-warm sidecar, and event-driven `repository_dispatch` rebuilds.** All rejected as more machinery than the outcome justifies.

#### Acceptance criteria

- With no volumes configured, every documented usage pattern starts as fast as today and `claude` runs the baked version. No regression.
- With the runtime volume configured: seed it from one image, pull a newer image, start a container, and `claude --version` still works — proving the symlink repair.
- A scheduled workflow run produces a different image digest than the preceding push-triggered run on the same commit, proving the cache removal took effect.
- A docs-only push does not trigger the publish workflow.
- Two containers started concurrently against the same volumes both run `claude` successfully.

## Description

// Will be filled in future stages by business analyst

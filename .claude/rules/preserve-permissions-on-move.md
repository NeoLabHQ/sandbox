---
title: Preserve Permissions and Bytes When Relocating Files
impact: HIGH
---

# Preserve Permissions and Bytes When Relocating Files

When a task requests moving (relocating) files with targeted text rewrites, the result must differ from the original ONLY in the rewrite. Mode bits, line endings, EOF-newlines, and trailing whitespace must be preserved. Even when a downstream step re-applies permissions (e.g., a Dockerfile chmod), the repo state must match intent — silent mode flips and editor auto-fixes corrupt review and break reproducibility.

## Incorrect

The agent reads each file with a content-loader, writes it to the new location with the Write tool (which uses the process umask, typically creating 0755 files for shell scripts), then runs `chmod +x` "to be safe." Trailing whitespace and EOF formatting are silently normalized by the writer. Diff against original now shows incidental whitespace edits and a mode flip on files that were originally 0644.

```bash
# Anti-pattern: read+write loses metadata and may auto-format
content=$(cat .devcontainer/install-mcps.sh)
echo "$content" > install-mcps.sh        # default umask → 0755 or 0644 depending on env
chmod +x install-mcps.sh                  # unconditional +x even if original was 0644
rm .devcontainer/install-mcps.sh
# diff vs original: mode changed + trailing-whitespace stripped + EOF newline added
```

## Correct

Use `git mv` for tracked files (preserves rename history AND mode bits), or `cp -p` / `install -m <orig-mode>` for an untracked relocate. Apply targeted substitutions with `sed -i` so only the intended bytes change. Verify with `diff` afterward.

```bash
# Preserve permissions, history, and bytes
git mv .devcontainer/install-mcps.sh install-mcps.sh
git mv .devcontainer/configure-claude.sh configure-claude.sh
git mv .devcontainer/statusline.sh statusline.sh

# Targeted rewrite — only the intended line changes
sed -i 's|/home/node/|$HOME/|g' configure-claude.sh

# Verify: diff should show ONLY the targeted substitution
git diff -- configure-claude.sh
stat -c '%a %n' *.sh   # confirm modes match originals (644/644/755)
```

## Reference

- `git mv` preserves mode bits and records the move as a rename.
- `cp -p` preserves mode, ownership, and timestamps.
- `install -m <mode>` sets an explicit mode when copying.
- Always `git diff` after a "move-only" step; the diff should show ONLY the requested rewrite.

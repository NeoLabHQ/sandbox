#!/usr/bin/env bash
set -euo pipefail

echo "🔧 Configuring Claude Code environment..."

# -- Copy statusline script to ~/.claude --
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p ~/.claude
cp "$SCRIPT_DIR/statusline.sh" ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh
echo "✅ Copied statusline.sh to ~/.claude/"

if [ ! -f ~/.claude/settings.json ]; then
  echo "🔧 Creating ~/.claude/settings.json..."
  cat > ~/.claude/settings.json << 'EOF'
{
  "permissions": {
    "defaultMode": "auto"
  },
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "echo 'codemap . && git diff:' && git diff --stat && echo 'git status:' && git status"
          }
        ]
      }
    ]
  },
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline.sh"
  },
  "alwaysThinkingEnabled": true,
  "skipDangerousModePermissionPrompt": true,
  "effortLevel": "high",
  "companyAnnouncements": ["Thank you for using NeoLab Dev Container Sandbox", "Happy engineering!"]
}
EOF
  echo "✅ Created ~/.claude/settings.json with bypass permissions."
fi

retry() {
  local max_attempts="${RETRY_ATTEMPTS:-3}"
  local delay="${RETRY_DELAY:-1}"
  local attempt=1
  while [ "$attempt" -le "$max_attempts" ]; do
    if "$@"; then
      return 0
    fi
    echo "⚠️ Attempt $attempt/$max_attempts failed: $*"
    if [ "$attempt" -lt "$max_attempts" ]; then
      echo "   Retrying in ${delay}s..."
      sleep "$delay"
    fi
    attempt=$((attempt + 1))
  done
  echo "❌ All $max_attempts attempts failed: $*"
  return 1
}

echo "🔧 Installing typescript lsp..."

retry claude plugin marketplace add anthropics/claude-plugins-official
retry claude plugin install typescript-lsp@claude-plugins-official

echo "🔧 Installing context-engineering-kit plugins..."

retry claude plugin marketplace add NeoLabHQ/context-engineering-kit
retry claude plugin install sdd@context-engineering-kit
retry claude plugin install sadd@context-engineering-kit
retry claude plugin install git@context-engineering-kit
retry claude plugin install ddd@context-engineering-kit
retry claude plugin install review@context-engineering-kit
retry claude plugin install tech-stack@context-engineering-kit
retry claude plugin install kaizen@context-engineering-kit

# Enable background auto-update for the context-engineering-kit marketplace.
# Based on https://gist.github.com/alexey-pelykh/566a4e5160b305db703d543312a1e686
KNOWN_MARKETPLACES_JSON="$HOME/.claude/plugins/known_marketplaces.json"
echo "🔧 Ensuring ${KNOWN_MARKETPLACES_JSON} auto-updates context-engineering-kit marketplace..."
tmp="$(mktemp)"
if [ -f "$KNOWN_MARKETPLACES_JSON" ]; then
  # Targeted assignment: touch only context-engineering-kit's autoUpdate flag.
  jq '.["context-engineering-kit"].autoUpdate = true' "$KNOWN_MARKETPLACES_JSON" >"$tmp"
else
  # Fallback when `marketplace add` did not produce the file: write a minimal entry
  # so the script stays safe under `set -euo pipefail`.
  jq -n --arg loc "$HOME/.claude/plugins/marketplaces/context-engineering-kit" '{
    "context-engineering-kit": {
      source: { source: "github", repo: "NeoLabHQ/context-engineering-kit" },
      "installLocation": $loc,
      "lastUpdated": "2026-06-20T19:53:12.421Z",
      autoUpdate: true
    }
  }' >"$tmp"
fi
mv "$tmp" "$KNOWN_MARKETPLACES_JSON"
echo "✅ ${KNOWN_MARKETPLACES_JSON} updated (context-engineering-kit autoUpdate=true; other entries preserved)."


# Merge only autoUpdates / autoCompactEnabled so we never replace the whole file (preserves other keys).
CLAUDE_JSON="$HOME/.claude.json"
echo "🔧 Ensuring ${CLAUDE_JSON} has autoUpdates and autoCompactEnabled..."
tmp="$(mktemp)"
if [ -f "$CLAUDE_JSON" ]; then
  jq '. + {autoUpdates: true, autoCompactEnabled: false, hasCompletedOnboarding: true}' "$CLAUDE_JSON" >"$tmp"
else
  jq -n '{autoUpdates: true, autoCompactEnabled: false, hasCompletedOnboarding: true}' >"$tmp"
fi
mv "$tmp" "$CLAUDE_JSON"
echo "✅ ${CLAUDE_JSON} updated (autoUpdates=true, autoCompactEnabled=false; other keys preserved)."

echo "🚀 Claude Code environment ready."
echo "Use 'claude' to run Claude Code"
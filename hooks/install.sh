#!/bin/bash
# Install the Claude Eyes hook for Claude Code:
#  - links ~/.claude/hooks/claude-state.sh to this repository's copy
#  - registers it on every hook event it handles in ~/.claude/settings.json (idempotent)
#  - turns off Claude Code's own terminal progress bar, which this hook replaces in Ghostty
set -euo pipefail

repoHook="$(cd "$(dirname "$0")" && pwd)/claude-state.sh"
target="$HOME/.claude/hooks/claude-state.sh"
settings="$HOME/.claude/settings.json"
events=(SessionStart UserPromptSubmit PreToolUse PostToolUse PostToolUseFailure PermissionRequest PermissionDenied
        Notification SubagentStart PreCompact PostCompact Stop StopFailure SessionEnd)

command -v jq > /dev/null || { echo "jq is required: brew install jq" >&2; exit 1; }

mkdir -p "$(dirname "$target")"
if [ -e "$target" ] && [ ! -L "$target" ]; then
  mv "$target" "$target.bak"
  echo "Existing hook saved to $target.bak"
fi
chmod +x "$repoHook"
ln -sfn "$repoHook" "$target"

[ -f "$settings" ] || echo '{}' > "$settings"
cp "$settings" "$settings.bak-claude-eyes"
eventsJson=$(printf '%s\n' "${events[@]}" | jq -R . | jq -s .)
jq --arg cmd "$target" --argjson events "$eventsJson" '
  .terminalProgressBarEnabled = false
  | .hooks = (reduce $events[] as $event (.hooks // {};
      if ((.[$event] // []) | map(.hooks[]?.command) | index($cmd)) then .
      else .[$event] = ((.[$event] // []) + [{"hooks": [{"type": "command", "command": $cmd, "timeout": 5}]}])
      end))
' "$settings" > "$settings.tmp" && mv "$settings.tmp" "$settings"

echo "Hook linked: $target -> $repoHook"
echo "Registered on ${#events[@]} events in $settings (backup: $settings.bak-claude-eyes)"

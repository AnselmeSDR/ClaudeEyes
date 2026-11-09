#!/bin/bash
# Install the Claude Eyes hook for Claude Code:
#  - links ~/.claude/hooks/claude-state.sh to this repository's copy, or with --copy (what the app does with
#    the hook it ships) copies it there, so it keeps working wherever the app goes
#  - registers it on every hook event it handles in ~/.claude/settings.json (idempotent)
#  - turns off Claude Code's own terminal progress bar, which this hook replaces in Ghostty
set -euo pipefail

sourceHook="$(cd "$(dirname "$0")" && pwd)/claude-state.sh"
target="$HOME/.claude/hooks/claude-state.sh"
settings="$HOME/.claude/settings.json"
events=(SessionStart UserPromptSubmit PreToolUse PostToolUse PostToolUseFailure PermissionRequest PermissionDenied
        Notification SubagentStart SubagentStop PreCompact PostCompact Stop StopFailure SessionEnd)
mode=link
[ "${1:-}" = "--copy" ] && mode=copy

command -v jq > /dev/null || { echo "jq is required: brew install jq" >&2; exit 1; }

mkdir -p "$(dirname "$target")"
if [ "$mode" = copy ]; then
  # Replaces a previous copy, or a link to a repository
  cp "$sourceHook" "$target.tmp"
  chmod +x "$target.tmp"
  mv -f "$target.tmp" "$target"
else
  if [ -e "$target" ] && [ ! -L "$target" ]; then
    mv "$target" "$target.bak"
    echo "Existing hook saved to $target.bak"
  fi
  chmod +x "$sourceHook"
  ln -sfn "$sourceHook" "$target"
fi

[ -e "$settings" ] || echo '{}' > "$settings"
# A settings file linked from elsewhere (dotfiles) stays a link: write to the file it points to
settingsFile=$(readlink -f "$settings")
eventsJson=$(printf '%s\n' "${events[@]}" | jq -R . | jq -s .)
jq --arg cmd "$target" --argjson events "$eventsJson" '
  .terminalProgressBarEnabled = false
  | .hooks = (reduce $events[] as $event (.hooks // {};
      if ((.[$event] // []) | map(.hooks[]?.command) | index($cmd)) then .
      else .[$event] = ((.[$event] // []) + [{"hooks": [{"type": "command", "command": $cmd, "timeout": 5}]}])
      end))
' "$settingsFile" > "$settingsFile.tmp"
# Nothing to change: the file and its formatting stay as they are
if jq -e --slurpfile new "$settingsFile.tmp" '. == $new[0]' "$settingsFile" > /dev/null; then
  rm -f "$settingsFile.tmp"
  registered="Already registered on ${#events[@]} events in $settings"
else
  cp "$settingsFile" "$settings.bak-claude-eyes"
  mv "$settingsFile.tmp" "$settingsFile"
  registered="Registered on ${#events[@]} events in $settings (backup: $settings.bak-claude-eyes)"
fi

if [ "$mode" = copy ]; then
  echo "Hook copied: $sourceHook -> $target"
else
  echo "Hook linked: $target -> $sourceHook"
fi
echo "$registered"

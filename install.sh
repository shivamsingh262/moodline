#!/bin/bash
# Installs moodline into Claude Code: copies the scripts and wires the status
# line and hooks into settings.json (backed up first).
# Usage: ./install.sh [--uninstall]
# shellcheck disable=SC2016 # $names in single quotes are jq variables
set -euo pipefail

claude_dir=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
dest="$claude_dir/moodline"
settings="$claude_dir/settings.json"
src=$(cd "$(dirname "$0")" && pwd)

command -v jq >/dev/null 2>&1 || { echo "moodline needs jq: brew install jq / apt install jq" >&2; exit 1; }

# Removes moodline hook commands, then any matcher groups and events left empty.
strip='
  def strip_hooks:
    if .hooks then
      .hooks |= (with_entries(.value |= (
          map(.hooks |= map(select((.command // "") | contains("moodline-hook.sh") | not)))
          | map(select(.hooks | length > 0))))
        | with_entries(select(.value | length > 0)))
      | if .hooks == {} then del(.hooks) else . end
    else . end;
'

mkdir -p "$claude_dir"
[ -f "$settings" ] || echo '{}' >"$settings"
jq empty "$settings" 2>/dev/null || { echo "$settings is not valid JSON; fix it first." >&2; exit 1; }

backup="$settings.moodline-backup.$(date +%Y%m%d%H%M%S)"
cp "$settings" "$backup"
tmp=$(mktemp "$settings.XXXXXX")
trap 'rm -f "$tmp"' EXIT

if [ "${1:-}" = "--uninstall" ]; then
  jq "$strip"'
    strip_hooks
    | if ((.statusLine.command // "") | contains("moodline/statusline.sh")) then del(.statusLine) else . end
  ' "$settings" >"$tmp"
  mv "$tmp" "$settings"
  rm -rf "$dest" "$claude_dir/moodline-state"
  echo "moodline removed. Settings backup: $backup"
  exit 0
fi

previous=$(jq -r '.statusLine.command // empty' "$settings")
if [ -n "$previous" ] && [ "$previous" != "$dest/statusline.sh" ]; then
  echo "Replacing your current status line: $previous"
fi

mkdir -p "$dest"
cp "$src/statusline.sh" "$src/moodline-hook.sh" "$dest/"
chmod +x "$dest/statusline.sh" "$dest/moodline-hook.sh"

jq --arg sl "$dest/statusline.sh" --arg hook "$dest/moodline-hook.sh" "$strip"'
  def add_hook($event; $arg):
    .hooks[$event] = (.hooks[$event] // []) + [{matcher: "", hooks: [{type: "command", command: "\($hook) \($arg)"}]}];
  strip_hooks
  | .statusLine = {type: "command", command: $sl}
  | add_hook("UserPromptSubmit"; "working")
  | add_hook("Stop"; "waiting")
  | add_hook("StopFailure"; "waiting")
  | add_hook("SessionEnd"; "end")
' "$settings" >"$tmp"
mv "$tmp" "$settings"

echo "moodline installed to $dest"
echo "Settings backup: $backup"
echo "Start a new Claude Code session to see it."

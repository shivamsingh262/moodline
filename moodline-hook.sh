#!/bin/bash
# Records whether Claude is working, for the moodline avatar.
# Usage: moodline-hook.sh working|waiting|end  (session JSON on stdin)
# Never blocks Claude: every failure exits 0.

state_dir=${MOODLINE_STATE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/moodline-state}

sid=$(jq -r '.session_id // "default"' 2>/dev/null)
case $sid in '' | */* | .*) sid=default ;; esac

mkdir -p "$state_dir" 2>/dev/null || exit 0
case $1 in
  end) rm -f "$state_dir/$sid" ;;
  working | waiting) printf '%s\n' "$1" >"$state_dir/$sid" ;;
esac
exit 0

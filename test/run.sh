#!/bin/bash
# Golden-file tests for statusline.sh plus an install/uninstall round trip.
# Usage: test/run.sh [--update]   (--update rewrites test/expected/)
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
update=""
[ "${1:-}" = "--update" ] && update=1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# A fake HOME so paths render as ~/..., with a plain dir and two git repos.
export HOME="$tmp/home" TZ=UTC MOODLINE_HIDE_HOST=1 MOODLINE_STATE_DIR="$tmp/state"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME/plain" "$HOME/clean" "$HOME/dirty" "$MOODLINE_STATE_DIR"
for repo in clean dirty; do
  git -C "$HOME/$repo" init -q -b main
  git -C "$HOME/$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
done
touch "$HOME/dirty/new-file"

day=1792333800   # 2026-10-18 14:30 UTC
night=1792293300 # 2026-10-18 03:15 UTC

fail=0
# check <name> <fixture> <dir> <state> <now> [ENV=value...]
check() {
  local name=$1 fixture=$2 dir=$3 state=$4 now=$5
  shift 5
  rm -f "$MOODLINE_STATE_DIR/test-session"
  [ "$state" = - ] || echo "$state" >"$MOODLINE_STATE_DIR/test-session"
  local out
  out=$(sed "s|__DIR__|$HOME/$dir|" "$root/test/fixtures/$fixture.json" |
    env MOODLINE_NOW="$now" "$@" "$root/statusline.sh" |
    sed $'s/\033\\[[0-9;]*m//g')
  if [ -n "$update" ]; then
    printf '%s\n' "$out" >"$root/test/expected/$name.txt"
  elif [ "$out" != "$(cat "$root/test/expected/$name.txt")" ]; then
    echo "FAIL $name"
    diff <(printf '%s\n' "$out") "$root/test/expected/$name.txt"
    fail=1
  else
    echo "ok   $name"
  fi
}

check full-clean full clean - "$day"
check dirty full dirty - "$day"
check no-repo minimal plain - "$day"
check working full clean working "$day"
check waiting full clean waiting "$day"
check night minimal clean - "$night"
check cold-cache cold-cache plain - "$day"
check over-200k over-200k plain - "$day"
check lines-filter full clean - "$day" MOODLINE_LINES=head,limits
check custom-face minimal clean - "$day" "MOODLINE_FACE_CLEAN=:)"

# Thresholds only change colors, so check the raw escape codes: ctx 42% is red at crit=40.
out=$(sed "s|__DIR__|$HOME/clean|" "$root/test/fixtures/full.json" |
  env MOODLINE_NOW="$day" MOODLINE_WARN=30 MOODLINE_CRIT=40 "$root/statusline.sh")
case $out in
  *$'ctx \033[31m'*) echo "ok   thresholds" ;;
  *) echo "FAIL thresholds"; fail=1 ;;
esac

# Bad input still exits 0 with a message.
if out=$(echo 'not json' | "$root/statusline.sh") && [ "$out" = "moodline: could not parse session JSON" ]; then
  echo "ok   bad-input"
else
  echo "FAIL bad-input: $out"; fail=1
fi

# Hook writes and clears session state.
echo '{"session_id":"hook-test"}' | "$root/moodline-hook.sh" working
if [ "$(cat "$MOODLINE_STATE_DIR/hook-test")" = working ]; then echo "ok   hook-write"; else echo "FAIL hook-write"; fail=1; fi
echo '{"session_id":"hook-test"}' | "$root/moodline-hook.sh" end
if [ ! -e "$MOODLINE_STATE_DIR/hook-test" ]; then echo "ok   hook-end"; else echo "FAIL hook-end"; fail=1; fi
echo '{"session_id":"../escape"}' | "$root/moodline-hook.sh" working
if [ ! -e "$tmp/escape" ]; then echo "ok   hook-path-safety"; else echo "FAIL hook-path-safety"; fail=1; fi

# Install keeps unrelated settings and hooks, is idempotent, and uninstalls cleanly.
export CLAUDE_CONFIG_DIR="$tmp/claude"
mkdir -p "$CLAUDE_CONFIG_DIR"
cat >"$CLAUDE_CONFIG_DIR/settings.json" <<'EOF'
{"theme":"dark","hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"other-hook"}]}]}}
EOF
original=$(jq -S . "$CLAUDE_CONFIG_DIR/settings.json")
"$root/install.sh" >/dev/null && "$root/install.sh" >/dev/null
s="$CLAUDE_CONFIG_DIR/settings.json"
if [ "$(jq -r .theme "$s")" = dark ] &&
  [ "$(jq -r .statusLine.command "$s")" = "$CLAUDE_CONFIG_DIR/moodline/statusline.sh" ] &&
  [ "$(jq '[.hooks[][].hooks[] | select(.command | contains("moodline-hook.sh"))] | length' "$s")" = 4 ] &&
  [ "$(jq '[.hooks.Stop[].hooks[] | select(.command == "other-hook")] | length' "$s")" = 1 ] &&
  [ -x "$CLAUDE_CONFIG_DIR/moodline/statusline.sh" ]; then
  echo "ok   install"
else
  echo "FAIL install"; jq . "$s"; fail=1
fi
"$root/install.sh" --uninstall >/dev/null
if [ "$(jq -S . "$s")" = "$original" ] && [ ! -e "$CLAUDE_CONFIG_DIR/moodline" ]; then
  echo "ok   uninstall"
else
  echo "FAIL uninstall"; jq . "$s"; fail=1
fi

exit $fail

#!/bin/bash
# moodline: a Claude Code status line with a small avatar whose mood follows
# the repo state, the time of day and whether Claude is working.
# Reads the session JSON on stdin and prints up to four framed lines.
# shellcheck disable=SC2154 # session fields are assigned by the eval below

warn=${MOODLINE_WARN:-50}
crit=${MOODLINE_CRIT:-80}
show=",${MOODLINE_LINES:-head,limits,spend,name},"
state_dir=${MOODLINE_STATE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/moodline-state}
now=${MOODLINE_NOW:-$(date +%s)}

face_working=${MOODLINE_FACE_WORKING:-'(ง •̀_•́)ง'}
face_waiting=${MOODLINE_FACE_WAITING:-'(・‿・)ﾉ'}
face_night=${MOODLINE_FACE_NIGHT:-'(－_－) zZ'}
face_norepo=${MOODLINE_FACE_NOREPO:-'(・ω・)'}
face_dirty=${MOODLINE_FACE_DIRTY:-'(•̀ᴗ•́)و'}
face_clean=${MOODLINE_FACE_CLEAN:-'(◕‿◕)'}

if ! command -v jq >/dev/null 2>&1; then
  printf 'moodline: jq is required (brew install jq / apt install jq)'
  exit 0
fi

# Format an epoch with BSD date (macOS) or GNU date (Linux).
fmt_epoch() {
  date -r "$2" "+$1" 2>/dev/null || date -d "@$2" "+$1"
}

# Pull every field in one jq call; missing values become empty strings.
vars=$(jq -r '
  def s: if . == null then "" else tostring end;
  def n: if type == "number" then floor | tostring else "" end;
  @sh "dir=\(.workspace.current_dir | s)",
  @sh "model=\(.model.display_name | s)",
  @sh "sid=\(.session_id | s)",
  @sh "name=\(.session_name | s)",
  @sh "effort=\(.effort.level | s)",
  @sh "fast=\(.fast_mode | s)",
  @sh "ctx=\(.context_window.used_percentage | n)",
  @sh "five=\(.rate_limits.five_hour.used_percentage | n)",
  @sh "five_reset=\(.rate_limits.five_hour.resets_at | n)",
  @sh "week=\(.rate_limits.seven_day.used_percentage | n)",
  @sh "week_reset=\(.rate_limits.seven_day.resets_at | n)",
  @sh "dur_ms=\(.cost.total_duration_ms | n)",
  @sh "cost=\(.cost.total_cost_usd | s)",
  @sh "cache_warm=\(.prompt_cache.warm | s)",
  @sh "cache_expires=\(.prompt_cache.expires_at | n)",
  @sh "recache=\(.prompt_cache.recache_tokens_if_cold | n)",
  @sh "over_200k=\(.exceeds_200k_tokens | s)"
' 2>/dev/null) || { printf 'moodline: could not parse session JSON'; exit 0; }
eval "$vars"

[ -n "$dir" ] || dir=$PWD
case $sid in '' | */* | .*) sid=default ;; esac
branch=$(git -C "$dir" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
state=$(cat "$state_dir/$sid" 2>/dev/null)

hour=$((10#$(fmt_epoch %H "$now")))
if [ "$state" = "working" ]; then
  face=$face_working; color=31
elif [ "$state" = "waiting" ]; then
  face=$face_waiting; color=36
elif [ "$hour" -lt 6 ]; then
  face=$face_night; color=35
elif [ -z "$branch" ]; then
  face=$face_norepo; color=36
elif [ -n "$(git -C "$dir" --no-optional-locks status --porcelain 2>/dev/null | head -1)" ]; then
  face=$face_dirty; color=33
else
  face=$face_clean; color=32
fi

sep=$'\033[90m · \033[0m'

# Join arguments with the gray dot separator.
join() {
  local out="$1" p
  shift
  for p in "$@"; do out="$out$sep$p"; done
  printf '%s' "$out"
}

# Usage percentages go green, then yellow at $warn, then red at $crit.
pct() {
  local c=32
  [ "$2" -ge "$warn" ] && c=33
  [ "$2" -ge "$crit" ] && c=31
  local filled=$((($2 + 19) / 20)) bar="" i
  [ "$filled" -gt 5 ] && filled=5
  for i in 1 2 3 4 5; do
    if [ "$i" -le "$filled" ]; then bar="${bar}▰"; else bar="${bar}▱"; fi
  done
  printf '\033[37m%s \033[%sm%s %d%%\033[0m' "$1" "$c" "$bar" "$2"
}

# Reset time: clock time when within a day, otherwise the weekday.
reset_at() {
  if [ $(($1 - now)) -lt 86400 ]; then
    printf '\033[90m→ %s\033[0m' "$(fmt_epoch %H:%M "$1")"
  else
    printf '\033[90m→ %s\033[0m' "$(fmt_epoch %a "$1")"
  fi
}

# Line 1: who and where, model and effort.
short=$dir
case $dir in "$HOME" | "$HOME"/*) short="~${dir#"$HOME"}" ;; esac
where=$(printf '\033[%sm%s\033[0m' "$color" "$face")
[ "$MOODLINE_HIDE_HOST" = 1 ] || where="$where $(printf '\033[32m%s@%s\033[0m' "$(whoami)" "$(hostname -s)")"
where="$where $(printf '\033[34m%s\033[0m' "$short")"
[ -n "$branch" ] && where="$where $(printf '\033[33m(%s)\033[0m' "$branch")"
id=("$where")
[ -n "$model" ] && id+=("$(printf '\033[35m%s\033[0m' "$model")")
[ -n "$effort" ] && id+=("$(printf '\033[36meffort:%s\033[0m' "$effort")")
[ "$fast" = "true" ] && id+=($'\033[93m⚡fast\033[0m')

# Line 2: context and plan usage limits.
limits=()
[ -n "$ctx" ] && limits+=("$(pct ctx "$ctx")")
if [ -n "$five" ]; then
  p=$(pct 5h "$five")
  [ -n "$five_reset" ] && p="$p $(reset_at "$five_reset")"
  limits+=("$p")
fi
if [ -n "$week" ]; then
  p=$(pct wk "$week")
  [ -n "$week_reset" ] && p="$p $(reset_at "$week_reset")"
  limits+=("$p")
fi

# Line 3: session duration, cost, prompt cache and compact hint.
spend=()
if [ -n "$dur_ms" ]; then
  mins=$((dur_ms / 60000))
  if [ "$mins" -ge 60 ]; then dur="$((mins / 60))h$((mins % 60))m"; else dur="${mins}m"; fi
  spend+=("$(printf '\033[94m⏱ %s\033[0m' "$dur")")
fi
[ -n "$cost" ] && spend+=("$(printf '\033[92m$%.2f\033[0m' "$cost")")
spend+=("$(printf '\033[97m🕐 %s\033[0m' "$(fmt_epoch %H:%M "$now")")")
size=""
[ -n "$recache" ] && size=" ($((recache / 1000))k)"
cold=""
if [ "$cache_warm" = "true" ] && [ -n "$cache_expires" ] && [ "$cache_expires" -gt "$now" ]; then
  spend+=("$(printf '\033[96mcache warm till %s%s\033[0m' "$(fmt_epoch %H:%M "$cache_expires")" "$size")")
elif [ -n "$cache_warm" ]; then
  cold=1
  spend+=("$(printf '\033[91mcache cold%s\033[0m' "$size")")
fi
# Compact hint: only when the context is large, or a cold cache would re-send a lot.
if [ "$over_200k" = "true" ]; then
  spend+=($'\033[33m💡 /compact\033[0m')
elif [ -n "$cold" ] && [ "${recache:-0}" -gt 150000 ]; then
  spend+=($'\033[33m💡 /compact before next msg\033[0m')
fi

lines=()
kinds=()
case $show in *,head,*) lines+=("$(join "${id[@]}")") && kinds+=(head) ;; esac
has_limits=""
case $show in *,limits,*)
  [ ${#limits[@]} -gt 0 ] && lines+=("$(join "${limits[@]}")") && kinds+=(branch) && has_limits=1
  ;;
esac
# Spend continues the usage group when limits are shown.
case $show in *,spend,*)
  lines+=("$(join "${spend[@]}")")
  if [ -n "$has_limits" ]; then kinds+=(cont); else kinds+=(branch); fi
  ;;
esac
case $show in *,name,*)
  [ -n "$name" ] && lines+=("$(printf '\033[3;97m%s\033[0m' "$name")") && kinds+=(branch)
  ;;
esac

# Draw the frame: ╭─ first, ├─ / │ in the middle, ╰─ last.
last=$((${#lines[@]} - 1))
for i in "${!lines[@]}"; do
  if [ "$last" -eq 0 ]; then frame='──'
  elif [ "$i" -eq 0 ]; then frame='╭─'
  elif [ "$i" -eq "$last" ]; then frame='╰─'
  elif [ "${kinds[$i]}" = cont ]; then frame='│ '
  else frame='├─'
  fi
  [ "$i" -gt 0 ] && printf '\n'
  printf '\033[90m%s\033[0m %s' "$frame" "${lines[$i]}"
done
exit 0

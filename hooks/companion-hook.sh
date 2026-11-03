#!/usr/bin/env bash
#
# Records what a Claude Code session is doing for the Claude Companion app.
# Installed to ~/.claude/hooks/companion-hook.sh by scripts/install-hooks.sh.
#
#   companion-hook.sh <needs|clear|prompt|stop|fail|end>    hook JSON arrives on stdin
#
# Writes ~/.claude/companion/events/<session_id>.<kind>.json, one small file per
# kind, so async hooks finishing out of order can never hide each other:
#   needs    a permission prompt, question or plan is waiting on you
#   clear    a tool ran (so any prompt was answered)
#   prompt   you sent a new prompt
#   outcome  how the last turn ended (stop or fail), with Claude's last message
#
# Must never break a turn: always exits 0.

set -uo pipefail

kind="${1:-clear}"
dir="$HOME/.claude/companion/events"
ts="$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%d", time*1000' 2>/dev/null || echo $(( $(date +%s) * 1000 )))"
input="$(cat)"

sid="$(jq -r '.session_id // empty' <<<"$input" 2>/dev/null)"
[[ "$sid" =~ ^[A-Za-z0-9-]+$ ]] || exit 0
mkdir -p "$dir" || exit 0

case "$kind" in
  end)
    rm -f "$dir/$sid".*.json
    exit 0
    ;;
  stop|fail) file="$dir/$sid.outcome.json" ;;
  needs)     file="$dir/$sid.needs.json" ;;
  prompt)    file="$dir/$sid.prompt.json" ;;
  *)         kind="clear"; file="$dir/$sid.clear.json" ;;
esac

json="$(jq -c --argjson ts "$ts" --arg kind "$kind" '{
  ts: $ts,
  kind: $kind,
  event: (.hook_event_name // null),
  type: (.notification_type // null),
  message: (.message // null),
  tool: (.tool_name // null),
  input: ((.tool_input // {}) as $i
          | if ($i | type) == "object"
            then { command: ($i.command // null),
                   file_path: ($i.file_path // null),
                   question: (try ($i.questions[0].question) catch null) }
            else {} end),
  last: ((.last_assistant_message // null) | if type == "string" then .[0:4000] else null end)
}' <<<"$input" 2>/dev/null)" || exit 0

# A Notification often follows PermissionRequest for the same prompt but without
# the tool details: keep the richer record.
if [[ "$kind" == "needs" && -f "$file" ]]; then
  if [[ "$(jq -r '.tool // empty' <<<"$json")" == "" ]]; then
    prev_ts="$(jq -r '.ts // 0' "$file" 2>/dev/null || echo 0)"
    prev_tool="$(jq -r '.tool // empty' "$file" 2>/dev/null)"
    if [[ -n "$prev_tool" && $(( ts - prev_ts )) -lt 15000 ]]; then
      exit 0
    fi
  fi
fi

printf '%s\n' "$json" > "$file.tmp.$$" && mv -f "$file.tmp.$$" "$file"
exit 0

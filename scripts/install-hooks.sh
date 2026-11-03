#!/usr/bin/env bash
#
# Installs companion-hook.sh into ~/.claude/hooks and registers it in
# ~/.claude/settings.json (a timestamped backup is written first).
# Safe to run again: existing companion entries are replaced, nothing else changes.
#
#   scripts/install-hooks.sh            install / update
#   scripts/install-hooks.sh --remove   take the companion hooks out again

set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
settings="$HOME/.claude/settings.json"
hook="$HOME/.claude/hooks/companion-hook.sh"
cmd="bash ~/.claude/hooks/companion-hook.sh"

[[ -f "$settings" ]] || echo '{}' > "$settings"
cp "$settings" "$settings.bak-companion-$(date +%Y%m%d-%H%M%S)"

# Drop any companion entries first, so this is idempotent.
strip='
  .hooks //= {}
  | .hooks |= with_entries(
      .value |= map(select(((.hooks // []) | map(.command // "") | any(test("companion-hook\\.sh"))) | not))
    )
  | .hooks |= with_entries(select(.value | length > 0))
'

if [[ "${1:-}" == "--remove" ]]; then
  jq "$strip" "$settings" > "$settings.tmp" && mv "$settings.tmp" "$settings"
  rm -f "$hook"
  echo "Removed the companion hooks from $settings"
  exit 0
fi

mkdir -p "$HOME/.claude/hooks"
install -m 0755 "$here/hooks/companion-hook.sh" "$hook"

jq --arg cmd "$cmd" "$strip"'
  | def entry($kind; $matcher):
      ({ hooks: [ { type: "command", command: ($cmd + " " + $kind), timeout: 5, async: true } ] }
       + (if $matcher == "" then {} else { matcher: $matcher } end));
    .hooks.PermissionRequest += [ entry("needs"; "") ]
  | .hooks.Notification      += [ entry("needs"; "permission_prompt|elicitation_dialog|agent_needs_input") ]
  | .hooks.PreToolUse        += [ entry("needs"; "AskUserQuestion|ExitPlanMode") ]
  | .hooks.PostToolUse       += [ entry("clear"; "") ]
  | .hooks.PermissionDenied  += [ entry("clear"; "") ]
  | .hooks.UserPromptSubmit  += [ entry("prompt"; "") ]
  | .hooks.Stop              += [ entry("stop"; "") ]
  | .hooks.StopFailure       += [ entry("fail"; "") ]
  | .hooks.SessionEnd        += [ entry("end"; "") ]
' "$settings" > "$settings.tmp"

# Only replace settings.json with something that is still valid JSON.
jq empty "$settings.tmp" && mv "$settings.tmp" "$settings"
echo "Installed $hook and registered it in $settings"
echo "New sessions use it right away; already-running ones may only pick it up after a restart."

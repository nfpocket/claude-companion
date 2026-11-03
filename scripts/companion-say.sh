#!/usr/bin/env bash
# Sends a command to the running Claude Companion as if you had said it.
#   scripts/companion-say.sh "what needs me"
#   scripts/companion-say.sh --snapshot      (writes window PNGs to ~/Library/Caches/ClaudeCompanion/)
#   scripts/companion-say.sh --pill          (opens or folds the notch pill)
if [[ "${1:-}" == "--pill" ]]; then
  osascript -l JavaScript -e 'ObjC.import("Foundation"); $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately("local.claude-companion.pill", $(), $(), true)' >/dev/null
  exit 0
fi
if [[ "${1:-}" == "--snapshot" ]]; then
  osascript -l JavaScript -e 'ObjC.import("Foundation"); $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately("local.claude-companion.snapshot", $(), $(), true)' >/dev/null
  exit 0
fi
osascript -l JavaScript - "$*" >/dev/null <<'JS'
ObjC.import("Foundation");
function run(argv) {
  const info = $.NSDictionary.dictionaryWithObjectForKey($(argv[0]), $("text"));
  $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately("local.claude-companion.heard", $(), info, true);
}
JS

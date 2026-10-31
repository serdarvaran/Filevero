#!/bin/zsh
# Starts a packaged app the way a user does (Turkish UI, so the localization catalog loads) and fails if it exits
# within the first seconds. Run it with the SwiftPM .build folder moved away: users do not have it.
set -euo pipefail
if (( $# != 1 )); then print -u2 'Usage: scripts/check-packaged-launch.sh APP'; exit 1; fi
executable="${1:A}/Contents/MacOS/Filevero"
"$executable" -appLanguage tr -hasCompletedWelcome YES -moveToApplicationsSuppressed YES &
pid=$!
sleep 10
if ! kill -0 $pid 2>/dev/null; then
  wait $pid && code=0 || code=$?
  print -u2 "Filevero exited during launch (status $code)"
  exit 1
fi
kill $pid
wait $pid 2>/dev/null || true
print "Filevero kept running after launch"

#!/bin/bash
# Picks and boots the Simulator the way the repo's simulator.yml does (the
# newest "iPhone N [Pro [Max]]"; the field test prefers iPhone 17 Pro Max),
# turns the hardware keyboard and the keyboard's helpers off, fixes the
# status bar, and writes out/sim.env and out/sim.json.
set -euo pipefail
. "$(dirname "$0")/common.sh"

# The software keyboard must show (typing goes through it).
defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false

xcrun simctl list devices available -j > "$OUT/simctl-devices.json"
node "$FT/ci/pick-sim.mjs" "$OUT/simctl-devices.json" "${FM_SIM_NAME:-iPhone 17 Pro Max}" > "$OUT/sim.json"
UDID=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).udid)' "$OUT/sim.json")
NAME=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).name)' "$OUT/sim.json")
RUNTIME=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).runtime)' "$OUT/sim.json")
log "Simulator: $NAME ($RUNTIME) $UDID"

boot() {
  xcrun simctl boot "$UDID" 2>/dev/null || true
  xcrun simctl bootstatus "$UDID" -b
}
# A failed boot gets one retry (06-RULES / AGENT-5 step 5).
if ! boot; then
  log "boot failed, retrying once"
  xcrun simctl shutdown "$UDID" 2>/dev/null || true
  sleep 5
  boot
fi

# No slide-to-type tutorial, no autocorrection or prediction: typed text stays exact.
for pref in "DidShowContinuousPathIntroduction -bool true" "KeyboardAutocorrection -bool false" \
            "KeyboardPrediction -bool false" "KeyboardAutocapitalization -bool false" \
            "KeyboardCheckSpelling -bool false" "KeyboardShowPredictionBar -bool false"; do
  # shellcheck disable=SC2086
  xcrun simctl spawn "$UDID" defaults write com.apple.Preferences $pref || true
done
# The same clock and bars in every screenshot and video.
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 \
  --cellularBars 4 --wifiBars 3 --dataNetwork wifi || true

cat > "$OUT/sim.env" <<EOF
UDID=$UDID
SIM_NAME="$NAME"
SIM_RUNTIME="$RUNTIME"
EOF
log "booted"

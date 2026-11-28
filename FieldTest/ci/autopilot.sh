#!/bin/bash
# autopilot.sh [scenario] [variant]: one evidence run driven by the app
# itself (-fmAutopilot 1), with no UI test attached, screen video and
# Simulator screenshots (H-I3: SwiftUI text without accessibility).
set -uo pipefail
. "$(dirname "$0")/common.sh"

SCENARIO=${1:-S6}
VARIANT=${2:-stream-img}
RUN_ID="ios-${SCENARIO}autopilot-$VARIANT-ev-$(printf '%04x' $((RANDOM % 65536)))"
RUN_DIR="$OUT/runs/$RUN_ID"
mkdir -p "$RUN_DIR"
read -r APP_ID EXE <<< "$(app_for_variant "$VARIANT")"

for id in "$SDK_APP_ID" "$OFF_APP_ID"; do
  xcrun simctl terminate "$UDID" "$id" > /dev/null 2>&1 || true
  xcrun simctl uninstall "$UDID" "$id" > /dev/null 2>&1 || true
done
xcrun simctl install "$UDID" "$PRODUCTS/$EXE.app"
gateway_post /ctl/run "{\"runId\":\"$RUN_ID\"}" > "$RUN_DIR/ctl-run.json"

node "$FT/ci/host-sampler.mjs" --match "/$EXE\\.app/$EXE( |\$)" --out "$RUN_DIR/host-samples.jsonl" &
SAMPLER=$!
node "$FT/ci/record.mjs" --udid "$UDID" --out "$RUN_DIR/screen.raw.mp4" --meta "$RUN_DIR/screen-recorder.json" &
RECORDER=$!
sleep 2

START_MS=$(now_ms)
START_LOG=$(date -r $((START_MS / 1000 - 5)) '+%Y-%m-%d %H:%M:%S')
node "$FT/ci/autopilot.mjs" --udid "$UDID" --app "$APP_ID" --run "$RUN_ID" --scenario "$SCENARIO" \
  --variant "$VARIANT" --out "$RUN_DIR" --journey "$FT/shared/journey.json" --campaign "${FM_CAMPAIGN:-manual}" \
  --target "ios-simulator $SIM_NAME $SIM_RUNTIME" 2> "$RUN_DIR/autopilot.log"
STATUS=$?
END_MS=$(now_ms)

kill -TERM "$RECORDER" 2>/dev/null || true
wait "$RECORDER" 2>/dev/null || true
kill -TERM "$SAMPLER" 2>/dev/null || true
wait "$SAMPLER" 2>/dev/null || true

DATA=$(xcrun simctl get_app_container "$UDID" "$APP_ID" data 2>/dev/null || true)
if [ -n "$DATA" ]; then
  cp "$DATA/Documents/fm-probe/$RUN_ID.jsonl" "$RUN_DIR/probe.jsonl" 2>/dev/null || true
  cp "$DATA/Documents/fm-markers/$RUN_ID.jsonl" "$RUN_DIR/markers.container.jsonl" 2>/dev/null || true
  cp "$DATA/Documents/fm-autopilot-$RUN_ID.log" "$RUN_DIR/autopilot-app.log" 2>/dev/null || true
fi
xcrun simctl spawn "$UDID" log show --style ndjson --info --debug --start "$START_LOG" \
  --predicate 'subsystem == "com.tracewayapp.fieldmart"' > "$RUN_DIR/app.log.ndjson" 2> /dev/null || true
xcrun simctl spawn "$UDID" log show --style ndjson --info --debug --start "$START_LOG" \
  --predicate "process == \"$EXE\"" > "$RUN_DIR/process.log.ndjson" 2> /dev/null || true
"$FT/ci/encode-video.sh" "$RUN_DIR" || true
curl -s -m 40 "$GATEWAY/ctl/quiet?run=$RUN_ID&ms=5000&timeout=30000" > "$RUN_DIR/quiet.json" || true
curl -s -m 5 "$GATEWAY/ctl/fxlog?run=$RUN_ID" > "$RUN_DIR/fxlog-counts.json" || true
cat > "$RUN_DIR/runner.json" <<EOF
{"runId": "$RUN_ID", "scenario": "$SCENARIO", "variant": "$VARIANT", "evidence": true, "driver": "autopilot",
 "app": "$APP_ID", "autopilotStatus": $STATUS, "startEpochMs": $START_MS, "endEpochMs": $END_MS,
 "simulator": "$SIM_NAME", "runtime": "$SIM_RUNTIME", "udid": "$UDID"}
EOF
log "autopilot run $RUN_ID done ($STATUS)"

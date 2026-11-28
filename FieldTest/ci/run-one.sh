#!/bin/bash
# run-one.sh <run id> <scenario> <variant> <evidence 0|1> [extra launch arguments…]
#
# One run of 03-MEASUREMENT.md §5.3 on the booted Simulator:
#   1. clean SDK state: both apps uninstalled, the one this variant uses
#      installed fresh (FieldmartOff for off/off2, Fieldmart otherwise);
#   2. a new ledger slice in the gateway (POST /ctl/run);
#   3. the host sampler, and in evidence runs the screen recording;
#   4. the XCUITest driver (JourneyTests/testRun) plays the scenario and the
#      standard ending (Home, 5 s, terminate);
#   5. the probe file and markers from the app's container, the unified log,
#      and a wait until the gateway has been quiet for 5 s.
# Everything lands in out/runs/<run id>/.
set -uo pipefail
. "$(dirname "$0")/common.sh"

RUN_ID=$1
SCENARIO=$2
VARIANT=$3
EVIDENCE=${4:-0}
shift 4 || true
EXTRA="$*"
RUN_DIR="$OUT/runs/$RUN_ID"
mkdir -p "$RUN_DIR"
read -r APP_ID EXE <<< "$(app_for_variant "$VARIANT")"
XCTESTRUN=$(xctestrun_file)
log "run $RUN_ID: $SCENARIO $VARIANT evidence=$EVIDENCE app=$APP_ID $EXTRA"

# 1. Clean state.
for id in "$SDK_APP_ID" "$OFF_APP_ID"; do
  xcrun simctl terminate "$UDID" "$id" > /dev/null 2>&1 || true
  xcrun simctl uninstall "$UDID" "$id" > /dev/null 2>&1 || true
done
xcrun simctl install "$UDID" "$PRODUCTS/$EXE.app"
# The driver's target app is installed by xcodebuild as well; keep only the one in use.
sleep 2

# 2. Ledger slice.
gateway_post /ctl/run "{\"runId\":\"$RUN_ID\"}" > "$RUN_DIR/ctl-run.json"

# 3. Samplers.
node "$FT/ci/host-sampler.mjs" --match "/$EXE\\.app/$EXE( |\$)" --out "$RUN_DIR/host-samples.jsonl" &
SAMPLER=$!
RECORDER=""
if [ "$EVIDENCE" = "1" ]; then
  node "$FT/ci/record.mjs" --udid "$UDID" --out "$RUN_DIR/screen.raw.mp4" --meta "$RUN_DIR/screen-recorder.json" &
  RECORDER=$!
  sleep 2
fi

# 4. The driver.
START_MS=$(now_ms)
START_LOG=$(date -r $((START_MS / 1000 - 5)) '+%Y-%m-%d %H:%M:%S')
export TEST_RUNNER_FM_RUN="$RUN_ID"
export TEST_RUNNER_FM_SCENARIO="$SCENARIO"
export TEST_RUNNER_FM_VARIANT="$VARIANT"
export TEST_RUNNER_FM_EVIDENCE="$EVIDENCE"
export TEST_RUNNER_FM_APP="$APP_ID"
export TEST_RUNNER_FM_OUT="$RUN_DIR"
export TEST_RUNNER_FM_CAMPAIGN="${FM_CAMPAIGN:-manual}"
export TEST_RUNNER_FM_TARGET="ios-simulator $SIM_NAME $SIM_RUNTIME"
export TEST_RUNNER_FM_EXTRA_ARGS="$EXTRA"
export TEST_RUNNER_FM_TYPE_MODE="${FM_TYPE_MODE:-paced}"
export TEST_RUNNER_FM_QUIESCENCE="${FM_QUIESCENCE:-wait}"
xcodebuild test-without-building \
  -xctestrun "$XCTESTRUN" \
  -destination "id=$UDID" \
  -parallel-testing-enabled NO \
  -only-testing:FieldmartUITests/JourneyTests/testRun \
  -resultBundlePath "$RUN_DIR/result.xcresult" \
  > "$RUN_DIR/xcodebuild.log" 2>&1
STATUS=$?
END_MS=$(now_ms)
log "driver finished with $STATUS after $(( (END_MS - START_MS) / 1000 )) s"

if [ -n "$RECORDER" ]; then
  kill -TERM "$RECORDER" 2>/dev/null || true
  wait "$RECORDER" 2>/dev/null || true
fi
kill -TERM "$SAMPLER" 2>/dev/null || true
wait "$SAMPLER" 2>/dev/null || true

# 5. What the app wrote, and its log.
DATA=$(xcrun simctl get_app_container "$UDID" "$APP_ID" data 2>/dev/null || true)
if [ -n "$DATA" ]; then
  cp "$DATA/Documents/fm-probe/$RUN_ID.jsonl" "$RUN_DIR/probe.jsonl" 2>/dev/null || true
  cp "$DATA/Documents/fm-markers/$RUN_ID.jsonl" "$RUN_DIR/markers.container.jsonl" 2>/dev/null || true
fi
xcrun simctl spawn "$UDID" log show --style ndjson --info --debug --start "$START_LOG" \
  --predicate 'subsystem == "com.tracewayapp.fieldmart"' > "$RUN_DIR/app.log.ndjson" 2> /dev/null || true
if [ "$EVIDENCE" = "1" ]; then
  # The SDK's own debug lines (NSLog: "[Traceway] wireframe capture takes …").
  xcrun simctl spawn "$UDID" log show --style ndjson --info --debug --start "$START_LOG" \
    --predicate "process == \"$EXE\"" > "$RUN_DIR/process.log.ndjson" 2> /dev/null || true
  "$FT/ci/encode-video.sh" "$RUN_DIR" || true
fi

# Quiet ledger: no new SDK request of the run for 5 s (at most 30 s). The
# ledger itself (out/ledger/<run>.jsonl, .fx.jsonl, bodies/<run>/) stays in
# the gateway's folder; the harness exports each run's slice.
curl -s -m 40 "$GATEWAY/ctl/quiet?run=$RUN_ID&ms=5000&timeout=30000" > "$RUN_DIR/quiet.json" || true
curl -s -m 5 "$GATEWAY/ctl/fxlog?run=$RUN_ID" > "$RUN_DIR/fxlog-counts.json" || true

# The result bundle is only kept when the driver failed or wrote nothing (it is large).
if [ ! -s "$RUN_DIR/driver.json" ] && [ -d "$RUN_DIR/result.xcresult" ]; then
  xcrun xcresulttool get log --path "$RUN_DIR/result.xcresult" --type console > "$RUN_DIR/xcresult-console.txt" 2>&1 || true
  xcrun xcresulttool get test-results tests --path "$RUN_DIR/result.xcresult" > "$RUN_DIR/xcresult-tests.json" 2>&1 || true
  STATUS=99
fi
if [ $STATUS -eq 0 ]; then
  rm -rf "$RUN_DIR/result.xcresult"
else
  (cd "$RUN_DIR" && zip -qr result.xcresult.zip result.xcresult && rm -rf result.xcresult) || true
  tail -40 "$RUN_DIR/xcodebuild.log"
fi

cat > "$RUN_DIR/runner.json" <<EOF
{"runId": "$RUN_ID", "scenario": "$SCENARIO", "variant": "$VARIANT", "evidence": $([ "$EVIDENCE" = "1" ] && echo true || echo false),
 "app": "$APP_ID", "extra": "$EXTRA", "xcodebuildStatus": $STATUS, "startEpochMs": $START_MS, "endEpochMs": $END_MS,
 "simulator": "$SIM_NAME", "runtime": "$SIM_RUNTIME", "udid": "$UDID"}
EOF
exit 0

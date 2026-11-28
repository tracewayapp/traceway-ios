#!/bin/bash
# run-one.sh <run id> <scenario> <variant> <evidence 0|1> [extra launch arguments…]
#
# One run of 03-MEASUREMENT.md §5.3 on the booted Simulator:
#   1. clean SDK state: both apps uninstalled, the one this variant uses
#      installed fresh (FieldmartOff for off/off2, Fieldmart otherwise);
#   2. a new ledger slice in the gateway (POST /ctl/run);
#   3. the host sampler, and in evidence runs the screen recording;
#   4. the XCUITest driver (JourneyTests/testJourney) plays the scenario and the
#      standard ending (Home, 5 s, terminate);
#   5. the probe file and markers from the app's container, the unified log,
#      and a wait until the gateway has been quiet for 5 s;
#   6. with -fmRelaunchAfterMs <ms> among the extra arguments (SDK builds
#      only): the app is opened again that long after the driver killed it,
#      without the driver, as run <run id>-relaunch, and killed 20 s later.
#      Its start ends the session the killed app could not end; what it sends
#      lands in this run's ledger slice. Pair it with -fmSessionInactivityMs
#      below <ms>, so the killed session has expired by then.
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
TOP_ARGS=()
if [ "${FM_PS_TOP:-0}" = 1 ]; then TOP_ARGS=(--top-out "$RUN_DIR/ps-top.jsonl"); fi
node "$FT/ci/host-sampler.mjs" --match "/$EXE\\.app/$EXE( |\$)" --out "$RUN_DIR/host-samples.jsonl" ${TOP_ARGS[@]+"${TOP_ARGS[@]}"} &
SAMPLER=$!
RECORDER=""
if [ "$EVIDENCE" = "1" ]; then
  if [ ! -f "$OUT/encoder-check.txt" ]; then "$FT/ci/encoder-check.sh" > "$OUT/encoder-check.txt" 2>&1 || true; fi
  node "$FT/ci/record.mjs" --udid "$UDID" --out "$RUN_DIR/screen.raw.mp4" --meta "$RUN_DIR/screen-recorder.json" \
    --renice "${FM_RECORDER_NICE:--15}" &
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
export TEST_RUNNER_FM_QUIESCENCE="${FM_QUIESCENCE:-skip}"
xcodebuild test-without-building \
  -xctestrun "$XCTESTRUN" \
  -destination "id=$UDID" \
  -parallel-testing-enabled NO \
  -only-testing:FieldmartUITests/JourneyTests/testJourney \
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

# The driver's files, if the test runner had to write them into its own container.
if [ ! -s "$RUN_DIR/driver.json" ]; then
  RUNNER_DATA=$(xcrun simctl get_app_container "$UDID" com.tracewayapp.fieldmart.uitests.xctrunner data 2>/dev/null || true)
  if [ -n "$RUNNER_DATA" ] && [ -d "$RUNNER_DATA/Documents/fm-out/$RUN_ID" ]; then
    cp -R "$RUNNER_DATA/Documents/fm-out/$RUN_ID/." "$RUN_DIR/"
    echo "copied from the test runner's container" > "$RUN_DIR/driver-files-from-runner-container.txt"
  fi
fi

# 5. What the app wrote, and its log.
DATA=$(xcrun simctl get_app_container "$UDID" "$APP_ID" data 2>/dev/null || true)
if [ -n "$DATA" ]; then
  cp "$DATA/Documents/fm-probe/$RUN_ID.jsonl" "$RUN_DIR/probe.jsonl" 2>/dev/null || true
  cp "$DATA/Documents/fm-markers/$RUN_ID.jsonl" "$RUN_DIR/markers.container.jsonl" 2>/dev/null || true
fi
xcrun simctl spawn "$UDID" log show --style ndjson --info --debug --start "$START_LOG" \
  --predicate 'subsystem == "com.tracewayapp.fieldmart"' > "$RUN_DIR/app.log.ndjson" 2> /dev/null || true
if [ "$EVIDENCE" = "1" ]; then
  # The SDK's own debug lines (NSLog: "[Traceway] wireframe capture takes …"),
  # not everything the process logs (that was 800 MB in the first smoke run).
  xcrun simctl spawn "$UDID" log show --style ndjson --info --debug --start "$START_LOG" \
    --predicate "process == \"$EXE\" AND eventMessage CONTAINS \"[Traceway]\"" \
    > "$RUN_DIR/process.log.ndjson" 2> /dev/null || true
  "$FT/ci/encode-video.sh" "$RUN_DIR" || true
fi

# Quiet ledger: no new SDK request of the run for 5 s (at most 30 s). The
# ledger itself (out/ledger/<run>.jsonl, .fx.jsonl, bodies/<run>/) stays in
# the gateway's folder; the harness exports each run's slice.
curl -s -m 40 "$GATEWAY/ctl/quiet?run=$RUN_ID&ms=5000&timeout=30000" > "$RUN_DIR/quiet.json" || true
curl -s -m 5 "$GATEWAY/ctl/fxlog?run=$RUN_ID" > "$RUN_DIR/fxlog-counts.json" || true

# 6. The relaunch.
RELAUNCH_MS=$(sed -nE 's/(^|.*[[:space:]])-fmRelaunchAfterMs[[:space:]]+([0-9]+).*/\2/p' <<< "$EXTRA")
if [ -n "$RELAUNCH_MS" ] && [ "$APP_ID" = "$SDK_APP_ID" ]; then
  WAIT_MS=$((RELAUNCH_MS - ($(now_ms) - END_MS)))
  if [ "$WAIT_MS" -gt 0 ]; then sleep $(((WAIT_MS + 999) / 1000)); fi
  read -r -a EXTRA_ARGS <<< "$EXTRA"
  RELAUNCH_START=$(now_ms)
  log "relaunch of $RUN_ID $((RELAUNCH_START - END_MS)) ms after the driver ended"
  xcrun simctl launch "$UDID" "$APP_ID" -fmRun "$RUN_ID-relaunch" -fmVariant "$VARIANT" -fmScenario "$SCENARIO" \
    -fmEvidence 0 -fmCampaign "${FM_CAMPAIGN:-manual}" -fmTarget "ios-simulator $SIM_NAME $SIM_RUNTIME" \
    ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} > "$RUN_DIR/relaunch.log" 2>&1 || true
  sleep 20
  xcrun simctl terminate "$UDID" "$APP_ID" >> "$RUN_DIR/relaunch.log" 2>&1 || true
  RELAUNCH_END=$(now_ms)
  curl -s -m 40 "$GATEWAY/ctl/quiet?run=$RUN_ID&ms=5000&timeout=30000" > "$RUN_DIR/relaunch-quiet.json" || true
  cat > "$RUN_DIR/relaunch.json" <<EOF2
{"runId": "$RUN_ID-relaunch", "afterMs": $RELAUNCH_MS, "startEpochMs": $RELAUNCH_START, "endEpochMs": $RELAUNCH_END}
EOF2
fi

# The result bundle is only kept when the driver wrote nothing (it is large);
# XCTest issues of a finished run are in driver.log.
if [ ! -s "$RUN_DIR/driver.json" ] && [ -d "$RUN_DIR/result.xcresult" ]; then
  xcrun xcresulttool get test-results tests --path "$RUN_DIR/result.xcresult" > "$RUN_DIR/xcresult-tests.json" 2>&1 || true
  STATUS=99
elif [ -s "$RUN_DIR/driver.json" ]; then
  STATUS=0
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

#!/bin/bash
# startup.sh <variants comma-separated> <launches per variant> [seed]
#
# Startup (03-MEASUREMENT.md §4, M-ST-1/M-ST-2, H-I6), outside any scenario:
#   pass "clean":    SDK state removed before every launch (app reinstalled);
#   pass "restored": state kept from the launch before (restored buffer and
#                    outbox).
# Per launch: cold (terminated), 3 s wait, `simctl launch`, 5 s, terminate.
# The app's own markers give process start (sysctl), FM_READY and FM_FULLY
# on one clock. Then XCTApplicationLaunchMetric (StartupTests/testLaunch)
# for each variant. Results in out/startup/.
set -uo pipefail
. "$(dirname "$0")/common.sh"

VARIANTS=${1:-off,core,buffer,stream-img}
N=${2:-10}
SEED=${3:-1112970949}
DIR="$OUT/startup"
mkdir -p "$DIR"
: > "$DIR/launches.jsonl"

ORDER=$(node "$FT/ci/shuffle.mjs" "$VARIANTS" "$SEED")
log "startup order: $ORDER"

# Not measured: the background load with no UI test attached. FieldmartOff,
# launched with simctl, idles 60 s while the busiest processes are logged
# every 10 s (ps-top-baseline.jsonl), to compare with ps-top.jsonl of runs.
read -r BASE_APP BASE_EXE <<< "$(app_for_variant off)"
xcrun simctl install "$UDID" "$PRODUCTS/$BASE_EXE.app"
node "$FT/ci/host-sampler.mjs" --match "/$BASE_EXE\\.app/$BASE_EXE( |\$)" --out "$DIR/host-samples-baseline.jsonl" \
  --top-out "$DIR/ps-top-baseline.jsonl" &
BASE_SAMPLER=$!
xcrun simctl launch "$UDID" "$BASE_APP" -fmRun "ios-S0baseline-off-$(printf '%04x' $((RANDOM % 65536)))" -fmVariant off \
  -fmScenario S0-startup -fmMarkers "$DIR/markers-baseline.jsonl" > /dev/null 2>&1 || true
sleep 65
xcrun simctl terminate "$UDID" "$BASE_APP" > /dev/null 2>&1 || true
kill "$BASE_SAMPLER" 2> /dev/null || true
wait "$BASE_SAMPLER" 2> /dev/null || true

for PASS in clean restored; do
  for VARIANT in $ORDER; do
    read -r APP_ID EXE <<< "$(app_for_variant "$VARIANT")"
    xcrun simctl uninstall "$UDID" "$APP_ID" > /dev/null 2>&1 || true
    xcrun simctl install "$UDID" "$PRODUCTS/$EXE.app"
    for I in $(seq 1 "$N"); do
      RUN_ID="ios-S0startup-$VARIANT-$PASS-$I-$(printf '%04x' $((RANDOM % 65536)))"
      MARKERS="$DIR/markers-$RUN_ID.jsonl"
      xcrun simctl terminate "$UDID" "$APP_ID" > /dev/null 2>&1 || true
      if [ "$PASS" = clean ] && [ "$I" -gt 1 ]; then
        xcrun simctl uninstall "$UDID" "$APP_ID" > /dev/null 2>&1 || true
        xcrun simctl install "$UDID" "$PRODUCTS/$EXE.app"
      fi
      gateway_post /ctl/run "{\"runId\":\"$RUN_ID\"}" > /dev/null
      sleep 3
      LAUNCH_MS=$(now_ms)
      xcrun simctl launch "$UDID" "$APP_ID" -fmRun "$RUN_ID" -fmVariant "$VARIANT" -fmScenario S0-startup \
        -fmMarkers "$MARKERS" > /dev/null 2>&1
      RETURNED_MS=$(now_ms)
      sleep 5
      xcrun simctl terminate "$UDID" "$APP_ID" > /dev/null 2>&1 || true
      node -e '
        const fs = require("fs");
        const [file, variant, pass, i, launch, returned, run] = process.argv.slice(1);
        const m = {};
        try {
          for (const line of fs.readFileSync(file, "utf8").split("\n").filter(Boolean)) {
            const j = JSON.parse(line); if (!(j.name in m)) m[j.name] = j;
          }
        } catch {}
        const at = (n) => (m[n] ? m[n].epochMs : null);
        const ready = at("FM_READY"), start = at("FM_PROC_START"), fully = at("FM_FULLY");
        console.log(JSON.stringify({ runId: run, variant, pass, i: Number(i), launchEpochMs: Number(launch),
          launchReturnedEpochMs: Number(returned), procStartEpochMs: start, readyEpochMs: ready, fullyEpochMs: fully,
          sdkStartMs: m.FM_SDK_STARTED ? Number(m.FM_SDK_STARTED.detail) : null,
          "M-ST-1": ready && start ? ready - start : null, "M-ST-2": fully && start ? fully - start : null,
          launchToReadyMs: ready ? ready - Number(launch) : null }));
      ' "$MARKERS" "$VARIANT" "$PASS" "$I" "$LAUNCH_MS" "$RETURNED_MS" "$RUN_ID" >> "$DIR/launches.jsonl"
    done
  done
done
log "simctl launches done: $(wc -l < "$DIR/launches.jsonl") lines"

# XCTApplicationLaunchMetric, restored state, per variant.
XCTESTRUN=$(xctestrun_file)
for VARIANT in $ORDER; do
  read -r APP_ID EXE <<< "$(app_for_variant "$VARIANT")"
  xcrun simctl install "$UDID" "$PRODUCTS/$EXE.app"
  RES="$DIR/metric-$VARIANT"
  mkdir -p "$RES"
  TEST_RUNNER_FM_RUN="ios-S0launchmetric-$VARIANT-$(printf '%04x' $((RANDOM % 65536)))" \
  TEST_RUNNER_FM_VARIANT="$VARIANT" TEST_RUNNER_FM_SCENARIO=S0-startup TEST_RUNNER_FM_APP="$APP_ID" \
  TEST_RUNNER_FM_OUT="$RES" TEST_RUNNER_FM_ITERATIONS="$N" \
  xcodebuild test-without-building -xctestrun "$XCTESTRUN" -destination "id=$UDID" -parallel-testing-enabled NO \
    -only-testing:FieldmartUITests/StartupTests/testLaunch -resultBundlePath "$RES/result.xcresult" \
    > "$RES/xcodebuild.log" 2>&1
  xcrun xcresulttool get test-results metrics --path "$RES/result.xcresult" > "$RES/metrics.json" 2> "$RES/metrics.err" || true
  grep -E "Launch|measured|average" "$RES/xcodebuild.log" | head -20 || true
  (cd "$RES" && zip -qr result.xcresult.zip result.xcresult && rm -rf result.xcresult) || true
done

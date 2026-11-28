#!/bin/bash
# launch-check.sh: the 30-second launch test of the first CI run. Each app is
# launched with `simctl launch` (no UI test attached), left for 30 s, pictured,
# terminated; its markers, probe file and log are kept in
# out/launch-check/<app>/. Fails when an app never wrote FM_READY.
set -uo pipefail
. "$(dirname "$0")/common.sh"

FAIL=0
for EXE in FieldmartOff Fieldmart; do
  if [ "$EXE" = Fieldmart ]; then APP_ID=$SDK_APP_ID; VARIANT=stream-img; else APP_ID=$OFF_APP_ID; VARIANT=off; fi
  DIR="$OUT/launch-check/$EXE"
  RUN_ID="ios-launch-$VARIANT-$(printf '%04x' $((RANDOM % 65536)))"
  mkdir -p "$DIR"
  xcrun simctl uninstall "$UDID" "$APP_ID" > /dev/null 2>&1 || true
  xcrun simctl install "$UDID" "$PRODUCTS/$EXE.app"
  gateway_post /ctl/run "{\"runId\":\"$RUN_ID\"}" > /dev/null
  START_LOG=$(date '+%Y-%m-%d %H:%M:%S')
  LAUNCH_MS=$(now_ms)
  xcrun simctl launch --terminate-running-process "$UDID" "$APP_ID" \
    -fmRun "$RUN_ID" -fmVariant "$VARIANT" -fmScenario launch -fmEvidence 1 -fmMarkers "$DIR/markers.jsonl" \
    > "$DIR/launch.txt" 2>&1
  sleep 30
  xcrun simctl io "$UDID" screenshot "$DIR/after-30s.png" > /dev/null 2>&1 || true
  xcrun simctl terminate "$UDID" "$APP_ID" > /dev/null 2>&1 || true
  DATA=$(xcrun simctl get_app_container "$UDID" "$APP_ID" data 2>/dev/null || true)
  [ -n "$DATA" ] && cp "$DATA/Documents/fm-probe/$RUN_ID.jsonl" "$DIR/probe.jsonl" 2>/dev/null
  [ -n "$DATA" ] && cp "$DATA/Documents/fm-markers/$RUN_ID.jsonl" "$DIR/markers.container.jsonl" 2>/dev/null
  xcrun simctl spawn "$UDID" log show --style ndjson --info --debug --start "$START_LOG" \
    --predicate "process == \"$EXE\" AND eventMessage CONTAINS \"[Traceway]\"" > "$DIR/process.log.ndjson" 2> /dev/null || true
  curl -s -m 5 "$GATEWAY/ctl/ledger?run=$RUN_ID" > "$DIR/ledger.json" || true
  echo "{\"runId\": \"$RUN_ID\", \"launchEpochMs\": $LAUNCH_MS}" > "$DIR/launch.json"
  if grep -q FM_READY "$DIR/markers.jsonl" 2>/dev/null || grep -q FM_READY "$DIR/markers.container.jsonl" 2>/dev/null; then
    log "$EXE: FM_READY seen; probe lines: $(wc -l < "$DIR/probe.jsonl" 2>/dev/null || echo 0); SDK requests: $(grep -o '"path":"/api/' "$DIR/ledger.json" | wc -l | tr -d ' ')"
    head -c 600 "$DIR/markers.jsonl" 2>/dev/null; echo
  else
    log "$EXE: no FM_READY marker"
    tail -30 "$DIR/process.log.ndjson" || true
    FAIL=1
  fi
done
exit $FAIL

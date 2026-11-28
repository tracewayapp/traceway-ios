#!/bin/bash
# run-plan.sh <plan.json>
#
# Runs every run of the plan in order on this one runner (variants of a
# scenario must be compared on the same machine). A driver that fails to
# start (no driver.json) gets one retry; nothing else is retried.
set -uo pipefail
. "$(dirname "$0")/common.sh"

PLAN=$1
COUNT=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).runs.length)' "$PLAN")
log "plan: $COUNT runs"
FAILED_STARTS=0
for index in $(seq 0 $((COUNT - 1))); do
  # runId scenario variant evidence(0|1) extra…
  LINE=$(node -e '
    const r = JSON.parse(require("fs").readFileSync(process.argv[1])).runs[Number(process.argv[2])];
    console.log([r.runId, r.scenario, r.variant, r.evidence ? 1 : 0, r.extra || ""].join("\t"));
  ' "$PLAN" "$index")
  IFS=$'\t' read -r RUN_ID SCENARIO VARIANT EVIDENCE EXTRA <<< "$LINE"
  log "[$((index + 1))/$COUNT] $RUN_ID"
  # shellcheck disable=SC2086
  "$FT/ci/run-one.sh" "$RUN_ID" "$SCENARIO" "$VARIANT" "$EVIDENCE" $EXTRA
  if [ ! -s "$OUT/runs/$RUN_ID/driver.json" ]; then
    FAILED=$RUN_ID
    mv "$OUT/runs/$FAILED" "$OUT/runs/$FAILED.failed-start" 2>/dev/null || true
    # A new id (new ledger slice) for the retry.
    RUN_ID="${FAILED%-*}-$(printf '%04x' $((RANDOM % 65536)))"
    log "$FAILED: the driver wrote nothing; one retry as $RUN_ID"
    # shellcheck disable=SC2086
    "$FT/ci/run-one.sh" "$RUN_ID" "$SCENARIO" "$VARIANT" "$EVIDENCE" $EXTRA
    echo "{\"retry\": true, \"retryOf\": \"$FAILED\"}" > "$OUT/runs/$RUN_ID/retry.json"
    if [ ! -s "$OUT/runs/$RUN_ID/driver.json" ]; then
      FAILED_STARTS=$((FAILED_STARTS + 1))
      # Something systematic: stop instead of burning the runner's hours.
      if [ $FAILED_STARTS -ge 2 ]; then
        log "two runs could not start the driver; stopping the plan"
        exit 1
      fi
    else
      FAILED_STARTS=0
    fi
  fi
done
log "plan done"

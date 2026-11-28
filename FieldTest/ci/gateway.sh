#!/bin/bash
# gateway.sh start|stop
#
# start: generates the fixtures with the vendored generator, checks them
# against the lock, and starts the vendored gateway in capture mode on
# 127.0.0.1:18190 (it answers the SDK itself and stores every request; the
# ledger comes back in the artifact and is forwarded into the local
# Traceway afterwards, 01-PLAN.md §4.2).
set -euo pipefail
. "$(dirname "$0")/common.sh"

SHARED="$FT/shared"
GATEWAY_JS="${FM_GATEWAY_JS:-$SHARED/gateway/gateway.mjs}"
FIXTURES_GEN="${FM_FIXTURES_GEN:-$SHARED/fixtures/gen.mjs}"
FIXTURES_DIR="$FT/fixtures"
LEDGER="$OUT/ledger"

case "${1:-start}" in
  start)
    mkdir -p "$LEDGER"
    if [ ! -f "$FIXTURES_DIR/.generated" ]; then
      log "generating fixtures"
      node "$FIXTURES_GEN" --out "$FIXTURES_DIR" > "$OUT/fixtures-gen.log" 2>&1
      touch "$FIXTURES_DIR/.generated"
    fi
    node "$FIXTURES_GEN" --check "$FIXTURES_DIR" --lock "$SHARED/fixtures.lock.json" > "$OUT/fixtures-check.log" 2>&1 \
      || { cat "$OUT/fixtures-check.log"; log "fixtures do not match the lock"; exit 1; }
    log "fixtures match the lock"
    nohup node "$GATEWAY_JS" --mode capture --port "$GATEWAY_PORT" --fixtures "$FIXTURES_DIR" \
      --ledger "$LEDGER" > "$OUT/gateway.log" 2>&1 &
    echo $! > "$OUT/gateway.pid"
    for _ in $(seq 1 50); do
      if curl -s -m 2 "$GATEWAY/ctl/health" > "$OUT/gateway-health.json" 2>/dev/null; then
        log "gateway up: $(cat "$OUT/gateway-health.json")"
        exit 0
      fi
      sleep 0.2
    done
    cat "$OUT/gateway.log"
    log "gateway did not start"
    exit 1
    ;;
  stop)
    if [ -f "$OUT/gateway.pid" ]; then
      kill "$(cat "$OUT/gateway.pid")" 2>/dev/null || true
      rm -f "$OUT/gateway.pid"
    fi
    ;;
esac

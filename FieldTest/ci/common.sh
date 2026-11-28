# Sourced by every ci/*.sh script (bash, on the macOS runner).
#
#   FT        FieldTest/ in the checkout
#   OUT       FieldTest/out/, uploaded as the workflow artifact
#   PRODUCTS  the Release-iphonesimulator products of build.sh
#   UDID      the booted Simulator (setup-sim.sh writes out/sim.env)

FT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${FM_OUT_ROOT:-$FT/out}"
DERIVED="${FM_DERIVED:-$FT/DerivedData}"
PRODUCTS="$DERIVED/Build/Products/Release-iphonesimulator"
GATEWAY_PORT=18190
GATEWAY="http://127.0.0.1:$GATEWAY_PORT"
SDK_APP_ID=com.tracewayapp.fieldmart
OFF_APP_ID=com.tracewayapp.fieldmart.off
mkdir -p "$OUT"

if [ -f "$OUT/sim.env" ]; then
  # shellcheck disable=SC1091
  . "$OUT/sim.env"
fi

now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000'; }

log() { echo "[$(date -u '+%H:%M:%S')] $*" >&2; }

# The app a variant runs: the SDK build for core/buffer/stream-*, the
# FieldmartOff build (no SDK linked) for off and off2.
app_for_variant() {
  case "$1" in
    off|off2) echo "$OFF_APP_ID FieldmartOff" ;;
    *) echo "$SDK_APP_ID Fieldmart" ;;
  esac
}

# The newest .xctestrun build-for-testing wrote.
xctestrun_file() {
  ls -t "$DERIVED"/Build/Products/*.xctestrun 2>/dev/null | head -1
}

# POST a JSON body to the gateway's control API (best effort).
gateway_post() {
  curl -s -m 5 -X POST -H 'Content-Type: application/json' -d "$2" "$GATEWAY$1" || true
}

#!/usr/bin/env bash
#
# Runs everything CI runs, locally — except the Firebase Test Lab device run
# (which needs Apple signing + GCP secrets). Mirrors .github/workflows/tests.yml.
#
#   ./Scripts/test.sh            # all local checks
#   ./Scripts/test.sh swift      # just `swift build` + `swift test`
#   ./Scripts/test.sh sim        # just the iOS Simulator XCTest run
#   ./Scripts/test.sh device     # just the device-arch build-for-testing compile
#
set -euo pipefail

cd "$(dirname "$0")/.."
STAGE="${1:-all}"

bold() { printf "\n\033[1m== %s ==\033[0m\n" "$1"; }

run_swift() {
  bold "swift build"
  swift build
  bold "swift test (host = macOS)"
  swift test
}

ensure_project() {
  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen not found — install with: brew install xcodegen" >&2
    exit 1
  fi
  bold "xcodegen generate"
  xcodegen generate
}

pick_sim() {
  xcrun simctl list devices available \
    | grep -oE 'iPhone [0-9]+( Pro( Max)?)?' | sort -V | tail -1
}

run_sim() {
  ensure_project
  local sim
  sim="$(pick_sim)"
  sim="${sim:-iPhone 16}"
  bold "xcodebuild test on iOS Simulator ($sim)"
  xcodebuild test \
    -project TracewayCI.xcodeproj \
    -scheme TracewayCI \
    -destination "platform=iOS Simulator,name=$sim"
}

run_device_build() {
  ensure_project
  bold "xcodebuild build-for-testing (iphoneos, unsigned compile check)"
  xcodebuild build-for-testing \
    -project TracewayCI.xcodeproj \
    -scheme TracewayCI \
    -configuration Debug \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -derivedDataPath .build/ftl_build \
    TRACEWAY_DSN="local-probe@https://example.com/api/report" \
    CODE_SIGNING_ALLOWED=NO
  echo "Device test bundle compiled. (CI signs it and runs it on Firebase Test Lab.)"
}

case "$STAGE" in
  swift)  run_swift ;;
  sim)    run_sim ;;
  device) run_device_build ;;
  all)    run_swift; run_sim; run_device_build ;;
  *) echo "usage: $0 [all|swift|sim|device]" >&2; exit 2 ;;
esac

bold "All local checks passed ✅"

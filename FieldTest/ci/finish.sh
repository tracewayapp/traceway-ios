#!/bin/bash
# finish.sh: the runner's environment record (03-MEASUREMENT.md §9) and the
# gateway stopped; prints what the artifact holds.
set -uo pipefail
. "$(dirname "$0")/common.sh"

"$FT/ci/gateway.sh" stop || true
GIT_COMMIT=$(git -C "$FT" rev-parse HEAD 2>/dev/null || echo unknown)
GIT_DIRTY=$(git -C "$FT" status --porcelain 2>/dev/null | grep -v '^??' | wc -l | tr -d ' ')
sha_of() { [ -f "$1" ] && echo "sha256:$(shasum -a 256 "$1" | cut -d' ' -f1)" || echo ""; }
JOURNEY_HASH=$(sha_of "$FT/shared/journey.json")
# tools/lib/hashes.mjs: the fixture hash is the lock's own hash over every file.
FIXTURES_HASH="sha256:$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).hash)' "$FT/shared/fixtures.lock.json" 2>/dev/null)"
{
  echo "{"
  echo "  \"platform\": \"ios\","
  echo "  \"commit\": \"$GIT_COMMIT\", \"dirtyFiles\": $GIT_DIRTY,"
  echo "  \"ref\": \"${GITHUB_REF:-}\", \"githubRunId\": \"${GITHUB_RUN_ID:-}\", \"githubRunAttempt\": \"${GITHUB_RUN_ATTEMPT:-}\","
  echo "  \"runnerImage\": \"${ImageOS:-} ${ImageVersion:-}\", \"runnerName\": \"${RUNNER_NAME:-}\","
  echo "  \"macos\": \"$(sw_vers -productVersion 2>/dev/null) $(sw_vers -buildVersion 2>/dev/null)\","
  echo "  \"cpu\": \"$(sysctl -n machdep.cpu.brand_string 2>/dev/null)\", \"cores\": $(sysctl -n hw.ncpu 2>/dev/null || echo 0),"
  echo "  \"memGB\": $(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 )),"
  echo "  \"xcode\": \"$(xcodebuild -version 2>/dev/null | tr '\n' ' ')\","
  echo "  \"node\": \"$(node --version)\","
  echo "  \"simulator\": \"${SIM_NAME:-}\", \"simulatorRuntime\": \"${SIM_RUNTIME:-}\", \"udid\": \"${UDID:-}\","
  echo "  \"journeyHash\": \"$JOURNEY_HASH\", \"fixturesHash\": \"$FIXTURES_HASH\","
  echo "  \"sharedVersion\": \"$(cat "$FT/shared/VERSION" 2>/dev/null || echo none)\""
  echo "}"
} > "$OUT/env.json"
cat "$OUT/env.json"
du -sh "$OUT" 2>/dev/null || true
du -sh "$OUT"/runs/* 2>/dev/null | sort -h | tail -10 || true

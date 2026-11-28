#!/bin/bash
# Generates the project and builds both apps and the UI tests for testing,
# Release configuration, for the booted Simulator. Then the size of each app
# (M-SIZE-1) and the proof that FieldmartOff holds nothing of the SDK.
set -euo pipefail
. "$(dirname "$0")/common.sh"
mkdir -p "$OUT/build"

cd "$FT"
xcodegen generate --spec project.yml > "$OUT/build/xcodegen.log" 2>&1 || { cat "$OUT/build/xcodegen.log"; exit 1; }

log "build-for-testing (Release)"
set +e
xcodebuild build-for-testing \
  -project FieldTest.xcodeproj \
  -scheme FieldTest \
  -configuration Release \
  -destination "id=$UDID" \
  -derivedDataPath "$DERIVED" \
  -clonedSourcePackagesDirPath "$FT/.spm" \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO \
  > "$OUT/build/xcodebuild.log" 2>&1
STATUS=$?
set -e
# The errors, readable in the job log without downloading the artifact.
grep -E "error:|warning: .*FieldTest/|BUILD (SUCCEEDED|FAILED)|TEST BUILD (SUCCEEDED|FAILED)" "$OUT/build/xcodebuild.log" \
  | grep -v "^ld: warning" | sort -u | head -200 || true
if [ $STATUS -ne 0 ]; then
  tail -80 "$OUT/build/xcodebuild.log"
  exit $STATUS
fi

XCTESTRUN=$(xctestrun_file)
log "products: $PRODUCTS"
log "xctestrun: $XCTESTRUN"
# No automatic screenshots or screen recordings by XCTest itself: they cost
# CPU in every measured run (the scheme says keepNever; this pins it for the
# test target in the .xctestrun the runs use).
for key in SystemAttachmentLifetime UserAttachmentLifetime; do
  plutil -replace "TestConfigurations.0.TestTargets.0.$key" -string keepNever "$XCTESTRUN" 2>/dev/null || true
done
plutil -replace "TestConfigurations.0.TestTargets.0.PreferredScreenCaptureFormat" -string screenshots "$XCTESTRUN" 2>/dev/null || true
plutil -p "$XCTESTRUN" > "$OUT/build/xctestrun.txt" 2>&1 || true
ls -la "$PRODUCTS" > "$OUT/build/products.txt"

# M-SIZE-1: the .app on disk and the executable's segments.
{
  echo "{"
  first=1
  for name in Fieldmart FieldmartOff; do
    app="$PRODUCTS/$name.app"
    kb=$(du -sk "$app" | cut -f1)
    exe_bytes=$(stat -f %z "$app/$name")
    text=$(size -m "$app/$name" | awk '/^Segment __TEXT:/ {print $3; exit}' || true)
    frameworks=$(ls "$app/Frameworks" 2>/dev/null | tr '\n' ' ' || true)
    [ $first -eq 1 ] || echo ","
    first=0
    printf '  "%s": {"appKb": %s, "executableBytes": %s, "textSegmentBytes": %s, "frameworks": "%s"}' \
      "$name" "$kb" "$exe_bytes" "${text:-null}" "$frameworks"
  done
  echo
  echo "}"
} > "$OUT/build/size.json"
for name in Fieldmart FieldmartOff; do size -m "$PRODUCTS/$name.app/$name" > "$OUT/build/size-m-$name.txt" || true; done
cat "$OUT/build/size.json"

# FieldmartOff must not contain the SDK: no Traceway or OpenTelemetry
# symbols, no SDK strings beyond the app's own (its log subsystem
# com.tracewayapp.fieldmart and the traceway-mask marker id), no frameworks.
OFF="$PRODUCTS/FieldmartOff.app/FieldmartOff"
{
  echo "nm Traceway symbols: $(nm "$OFF" 2>/dev/null | grep -ci 'traceway' || true)"
  echo "nm OpenTelemetry symbols: $(nm "$OFF" 2>/dev/null | grep -ci 'opentelemetry' || true)"
  echo "strings matching traceway (all): $(strings - "$OFF" | grep -ci 'traceway' || true)"
  echo "strings matching traceway (beyond com.tracewayapp.fieldmart and traceway-mask):"
  strings - "$OFF" | grep -i 'traceway' | grep -v -e 'com\.tracewayapp\.fieldmart' -e '^traceway-mask$' -e '/traceway-ios/' \
    | sort -u || true
  echo "(build paths of the checkout folder traceway-ios/ are left out: they name the folder, not the SDK)"
  echo "otool -L:"
  otool -L "$OFF"
  echo "Frameworks folder: $(ls "$PRODUCTS/FieldmartOff.app/Frameworks" 2>/dev/null | tr '\n' ' ')"
  echo "--- the SDK build, for comparison ---"
  echo "nm Traceway symbols in Fieldmart: $(nm "$PRODUCTS/Fieldmart.app/Fieldmart" 2>/dev/null | grep -ci 'traceway' || true)"
} > "$OUT/build/off-clean.txt" 2>&1
cat "$OUT/build/off-clean.txt"

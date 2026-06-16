#!/usr/bin/env bash
#
# Uploads this build's dSYM debug symbols to Traceway. The backend parses the
# Mach-O + DWARF and builds its symbol cache; this script only *sends* the raw
# dSYMs (no parsing client-side). Intended as an Xcode "Run Script" build phase
# on Release builds, but also runnable by hand:
#
#   TRACEWAY_UPLOAD_TOKEN=<token> ./Scripts/upload_symbols.sh [--dsym-dir DIR] [--url URL] [--dry-run]
#
# It no-ops safely (exit 0) on non-Release builds or when the token is unset, so
# it never fails a debug build.
set -euo pipefail

token="${TRACEWAY_UPLOAD_TOKEN:-}"
url="${TRACEWAY_URL:-https://cloud.tracewayapp.com}"
dsym_dir="${DWARF_DSYM_FOLDER_PATH:-}"
dry_run=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --token)    token="$2"; shift 2 ;;
    --url)      url="$2"; shift 2 ;;
    --dsym-dir) dsym_dir="$2"; shift 2 ;;
    --dry-run)  dry_run=1; shift ;;
    *) echo "traceway: ignoring unknown arg $1" >&2; shift ;;
  esac
done

if [ "${CONFIGURATION:-Release}" != "Release" ]; then
  echo "traceway: skipping symbol upload (CONFIGURATION=${CONFIGURATION:-unset})"
  exit 0
fi
if [ "$dry_run" != "1" ] && [ -z "$token" ]; then
  echo "traceway: TRACEWAY_UPLOAD_TOKEN not set — skipping symbol upload" >&2
  exit 0
fi
if [ -z "$dsym_dir" ]; then
  echo "traceway: no dSYM dir (set DWARF_DSYM_FOLDER_PATH or --dsym-dir) — skipping" >&2
  exit 0
fi

# Derive the upload URL from a base URL or a report URL.
if printf '%s' "$url" | grep -q '/api/report'; then
  upload_url="$(printf '%s' "$url" | sed 's|/api/report|/api/symbols/upload|')"
elif printf '%s' "$url" | grep -q '/api/symbols/upload$'; then
  upload_url="$url"
else
  upload_url="${url%/}/api/symbols/upload"
fi

count=0
while IFS= read -r dwarf; do
  [ -f "$dwarf" ] || continue
  name="$(basename "$dwarf")"
  if [ "$dry_run" = "1" ]; then
    echo "traceway: would upload $name -> $upload_url"
    count=$((count + 1))
    continue
  fi
  echo "traceway: uploading $name"
  if curl -fsS --retry 2 --retry-connrefused -H "Authorization: Bearer $token" -F "files=@$dwarf" "$upload_url" >/dev/null; then
    count=$((count + 1))
  else
    echo "traceway: upload failed for $name" >&2
  fi
done < <(find "$dsym_dir" -type f -path '*.dSYM/Contents/Resources/DWARF/*')

echo "traceway: ${count} dSYM binary(ies) $([ "$dry_run" = "1" ] && echo 'would be uploaded' || echo 'uploaded') -> $upload_url"

#!/usr/bin/env bash
#
# Uploads this build's dSYM debug symbols to Traceway. The backend parses the
# Mach-O + DWARF and builds its symbol cache; this script only *sends* the raw
# dSYMs (no parsing client-side). Intended as the last Xcode "Run Script" build
# phase of the app target (see "Upload dSYMs" in the README), but also runnable
# by hand:
#
#   TRACEWAY_UPLOAD_TOKEN=<token> ./Scripts/upload_symbols.sh [--dsym-dir DIR] [--url URL] [--dry-run]
#
# Build settings reach it as environment variables: TRACEWAY_UPLOAD_TOKEN (the
# upload token `traceway setup` creates), TRACEWAY_URL (a self-hosted server;
# Traceway Cloud otherwise) and TRACEWAY_UPLOAD_DEBUG=YES to upload from Debug
# builds too. It never fails a build: problems are Xcode warnings
# ("warning: traceway: ..."), and non-Release builds are skipped unless
# TRACEWAY_UPLOAD_DEBUG is set.
set -euo pipefail

token="${TRACEWAY_UPLOAD_TOKEN:-}"
url="${TRACEWAY_URL:-https://cloud.tracewayapp.com}"
dsym_dir="${DWARF_DSYM_FOLDER_PATH:-}"
upload_debug="${TRACEWAY_UPLOAD_DEBUG:-NO}"
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

warn() { echo "warning: traceway: $*"; }

# A blank --url or TRACEWAY_URL is Traceway Cloud, as an unset one is.
url="$(printf '%s' "$url" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
[ -n "$url" ] || url="https://cloud.tracewayapp.com"

case "$upload_debug" in
  YES|yes|Yes|1|true|TRUE) upload_debug=1 ;;
  *) upload_debug=0 ;;
esac
if [ "${CONFIGURATION:-Release}" != "Release" ] && [ "$upload_debug" != "1" ]; then
  echo "traceway: skipping symbol upload (CONFIGURATION=${CONFIGURATION:-unset}; TRACEWAY_UPLOAD_DEBUG=YES uploads it too)"
  exit 0
fi
if [ "$dry_run" != "1" ] && [ -z "$token" ]; then
  warn "TRACEWAY_UPLOAD_TOKEN is not set, so no dSYM was uploaded and crashes of this build stay unsymbolicated. Set it in Traceway.xcconfig or the CI environment."
  exit 0
fi
if [ -z "$dsym_dir" ]; then
  warn "no dSYM folder (DWARF_DSYM_FOLDER_PATH is empty; pass --dsym-dir). Set Debug Information Format to \"DWARF with dSYM File\"."
  exit 0
fi

# The server's base URL by the rules every Traceway SDK uses: trimmed, https://
# added without a scheme (http:// for a local host), query, fragment and
# trailing slashes dropped, then a trailing /api/report, else /api.
normalize_base_url() {
  local u="$1" authority host
  u="$(printf '%s' "$u" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  case "$u" in
    *://*) ;;
    *)
      authority="${u%%[/?#]*}"
      case "$authority" in
        \[*) host="${authority%%]*}]" ;;
        *) host="${authority%%:*}" ;;
      esac
      case "$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')" in
        localhost|127.0.0.1|10.0.2.2|"[::1]") u="http://$u" ;;
        *) u="https://$u" ;;
      esac
      ;;
  esac
  u="${u%%#*}"
  u="${u%%\?*}"
  while [ "${u%/}" != "$u" ]; do u="${u%/}"; done
  case "$u" in
    */api/report) u="${u%/api/report}" ;;
    */api) u="${u%/api}" ;;
  esac
  while [ "${u%/}" != "$u" ]; do u="${u%/}"; done
  printf '%s' "$u"
}

trimmed_url="$(printf '%s' "$url" | sed -e 's/[[:space:]]*$//' -e 's|/*$||')"
case "$trimmed_url" in
  */api/symbols/upload) upload_url="$trimmed_url" ;;
  *) upload_url="$(normalize_base_url "$url")/api/symbols/upload" ;;
esac
case "$upload_url" in
  http://*|https://*) ;;
  *) warn "\"$url\" is not a Traceway server URL; expected https://host"; exit 0 ;;
esac

# Every DWARF file of the build's dSYMs. Under User Script Sandboxing the
# folder itself may not be listable; then only the app's own dSYM is, when the
# phase lists $(DWARF_DSYM_FOLDER_PATH)/$(DWARF_DSYM_FILE_NAME) as an input.
dwarf_files() {
  local found
  found="$(find "$dsym_dir" -type f -path '*.dSYM/Contents/Resources/DWARF/*' 2>/dev/null || true)"
  if [ -z "$found" ] && [ -n "${DWARF_DSYM_FILE_NAME:-}" ] && [ -d "$dsym_dir/$DWARF_DSYM_FILE_NAME" ]; then
    found="$(find "$dsym_dir/$DWARF_DSYM_FILE_NAME" -type f -path '*/Contents/Resources/DWARF/*' 2>/dev/null || true)"
  fi
  [ -n "$found" ] && printf '%s\n' "$found"
  return 0
}

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
  status="$(curl -sS --retry 2 --retry-connrefused -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $token" -F "files=@$dwarf" "$upload_url" || true)"
  case "$status" in
    2??) count=$((count + 1)) ;;
    401|403) warn "upload of $name rejected (HTTP $status): check TRACEWAY_UPLOAD_TOKEN" ;;
    000|"") warn "upload of $name failed: $upload_url did not answer" ;;
    *) warn "upload of $name failed (HTTP $status at $upload_url)" ;;
  esac
done < <(dwarf_files)

if [ "$count" = "0" ] && [ -z "$(dwarf_files)" ]; then
  warn "no dSYM found in $dsym_dir. Set Debug Information Format to \"DWARF with dSYM File\" (Debug builds have none by default), and User Script Sandboxing to No for the app target."
fi

echo "traceway: ${count} dSYM binary(ies) $([ "$dry_run" = "1" ] && echo 'would be uploaded' || echo 'uploaded') -> $upload_url"

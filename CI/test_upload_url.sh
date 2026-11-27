#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
dsym_dir=$(mktemp -d)
trap 'rm -rf "$dsym_dir"' EXIT
mkdir -p "$dsym_dir/App.dSYM/Contents/Resources/DWARF"
touch "$dsym_dir/App.dSYM/Contents/Resources/DWARF/App"

check() {
    output=$(CONFIGURATION=Release Scripts/upload_symbols.sh --dry-run --dsym-dir "$dsym_dir" --url "$1")
    if ! printf '%s\n' "$output" | grep -Fxq "traceway: would upload App -> $2/api/symbols/upload"; then
        printf 'Unexpected dry-run destination for %s\n%s\n' "$1" "$output" >&2
        exit 1
    fi
}

check 'http://api' 'http://api'
check 'api?x=123' 'https://api'
check 'http://api/report' 'http://api/report'
check 'http://api/api/report/' 'http://api'
check 'localhost:8090/proxy/api/' 'http://localhost:8090/proxy'
check 'http://api/api/symbols/upload/' 'http://api'
check 'http://api/symbols/upload' 'http://api/symbols/upload'
check 'api/api/symbols/upload' 'https://api'
check 'HTTP://api' 'http://api'

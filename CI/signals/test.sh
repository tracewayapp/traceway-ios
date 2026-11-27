#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cc "$@" -Wall -Werror -pthread -I Sources/TracewaySignalSupport/include Sources/TracewaySignalSupport/SignalSupport.c CI/signals/test.c -o "$out/test"
"$out/test"

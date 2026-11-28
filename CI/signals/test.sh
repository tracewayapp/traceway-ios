#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
# The swift Docker image has clang and no cc.
if [ -z "${CC:-}" ]; then
  if command -v cc >/dev/null 2>&1; then CC=cc; else CC=clang; fi
fi
"$CC" "$@" -Wall -Werror -pthread -I Sources/TracewaySignalSupport/include Sources/TracewaySignalSupport/SignalSupport.c CI/signals/test.c -o "$out/test"
"$out/test"

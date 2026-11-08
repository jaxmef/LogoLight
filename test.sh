#!/bin/zsh
# Runs the hardware-free tests (same toolchain choice as build.sh).
set -eu
cd "${0:A:h}"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Library/Developer/CommandLineTools ]]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
# The Command Line Tools' SwiftPM sometimes doesn't pass the Swift Testing macro plugin to the compiler.
plugins="${DEVELOPER_DIR:-}/usr/lib/swift/host/plugins/testing"
if [[ -n "${DEVELOPER_DIR:-}" && -d "$plugins" ]]; then
  swift test -Xswiftc -plugin-path -Xswiftc "$plugins" "$@"
else
  swift test "$@"
fi

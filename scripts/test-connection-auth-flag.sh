#!/bin/bash
# Standalone test runner for ConnectionConfig.requiresAuthentication — the
# per-connection Touch ID gate's stored flag: its decode from the FFI document,
# its round trip back, and the equality the connections form's dirty state uses.
# No Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$(mktemp -t connection-auth-flag-tests)"
trap 'rm -f "$BIN"' EXIT
swiftc -o "$BIN" \
  Pharos/Models/Connection.swift \
  PharosTests/ConnectionAuthFlagTests.swift \
  PharosTests/main.swift
"$BIN"

#!/bin/bash
# Standalone test runner for ConnectionConfig.engine, the engine
# capabilities and the DuckDB open-error markers (Pharos/Models/Connection.swift).
# No Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$(mktemp -t connection-engine-tests)"
trap 'rm -f "$BIN"' EXIT
swiftc -o "$BIN" \
  Pharos/Models/Connection.swift \
  PharosTests/ConnectionEngineTests.swift \
  PharosTests/main.swift
"$BIN"

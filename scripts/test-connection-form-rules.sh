#!/bin/bash
# Standalone test runner for ConnectionFormRules: the Connections Manager's
# per-engine sections, validation and the DuckDB record's normal form.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$(mktemp -t connection-form-rules-tests)"
trap 'rm -f "$BIN"' EXIT
swiftc -o "$BIN" \
  Pharos/Models/Connection.swift \
  Pharos/Core/ConnectionFormRules.swift \
  PharosTests/ConnectionFormRulesTests.swift \
  PharosTests/main.swift
"$BIN"

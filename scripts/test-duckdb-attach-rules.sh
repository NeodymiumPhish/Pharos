#!/bin/bash
# Standalone test runner for DuckDBAttachRules: what the Attach Database sheet
# offers, its default alias (a mirror of pharos-core's
# duck_attach::default_alias), the database-file check and the navigator's
# attached-database test and subtitle.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$(mktemp -t duckdb-attach-rules-tests)"
trap 'rm -f "$BIN"' EXIT
swiftc -o "$BIN" \
  Pharos/Models/Connection.swift \
  Pharos/Core/DuckDBFiles.swift \
  Pharos/Core/DataFiles.swift \
  Pharos/Core/DuckDBAttachRules.swift \
  PharosTests/DuckDBAttachRulesTests.swift \
  PharosTests/main.swift
"$BIN"

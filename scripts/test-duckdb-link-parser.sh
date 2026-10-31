#!/bin/bash
# Standalone test runner for DuckDBLinkParser (the pharos://duckdb/attach link).
# Foundation only — the parser has no AppKit or FFI dependency.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$(mktemp -t duckdb-link-parser-tests)"
trap 'rm -f "$BIN"' EXIT
swiftc -o "$BIN" \
  Pharos/Utilities/DuckDBLinkParser.swift \
  PharosTests/DuckDBLinkParserTests.swift \
  PharosTests/main.swift
"$BIN"

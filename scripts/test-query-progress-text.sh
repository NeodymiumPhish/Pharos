#!/bin/bash
# Standalone test runner for QueryProgressText: the card header's line while a
# query runs (Pharos/Core/QueryProgressText.swift).
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$(mktemp -t query-progress-text-tests)"
trap 'rm -f "$BIN"' EXIT
swiftc -o "$BIN" \
  Pharos/Core/QueryProgressText.swift \
  PharosTests/QueryProgressTextTests.swift \
  PharosTests/main.swift
"$BIN"

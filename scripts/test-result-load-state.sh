#!/bin/bash
# Standalone test runner for ResultLoadState: "(more available)" /
# "(limit reached)" and when Load More / Load All are offered.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$(mktemp -t result-load-state-tests)"
trap 'rm -f "$BIN"' EXIT
swiftc -o "$BIN" \
  Pharos/Core/ResultLoadState.swift \
  PharosTests/ResultLoadStateTests.swift \
  PharosTests/main.swift
"$BIN"

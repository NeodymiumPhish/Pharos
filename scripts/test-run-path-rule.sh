#!/bin/bash
# Standalone test runner for RunPathRule: which cards run on the row path and
# which on the statement path, per engine.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$(mktemp -t run-path-rule-tests)"
trap 'rm -f "$BIN"' EXIT
swiftc -o "$BIN" \
  Pharos/Models/Connection.swift \
  Pharos/Core/RunPathRule.swift \
  PharosTests/RunPathRuleTests.swift \
  PharosTests/main.swift
"$BIN"

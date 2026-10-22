#!/bin/bash
# Standalone test runner for DockMenuRule: which records the Dock icon's menu lists.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$(mktemp -t dock-menu-rule-tests)"
trap 'rm -f "$BIN"' EXIT
swiftc -o "$BIN" \
  Pharos/Models/Connection.swift \
  Pharos/Core/DockMenuRule.swift \
  PharosTests/DockMenuRuleTests.swift \
  PharosTests/main.swift
"$BIN"

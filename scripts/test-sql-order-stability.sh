#!/bin/bash
# Standalone test runner for SQLOrderStability — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/sql-order-stability-tests \
  Pharos/Editor/SQLLexer.swift \
  Pharos/Editor/SQLLexSnapshot.swift \
  Pharos/Utilities/SQLOrderStability.swift \
  PharosTests/SQLOrderStabilityTests.swift \
  PharosTests/main.swift
/tmp/sql-order-stability-tests

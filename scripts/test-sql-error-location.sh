#!/bin/bash
# Standalone test runner for SQLErrorLocation — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/sql-error-location-tests \
  Pharos/Core/SQLErrorLocation.swift \
  PharosTests/SQLErrorLocationTests.swift \
  PharosTests/main.swift
/tmp/sql-error-location-tests

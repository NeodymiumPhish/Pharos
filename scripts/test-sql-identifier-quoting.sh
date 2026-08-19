#!/bin/bash
# Standalone test runner for SqlIdentifierQuoting — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/sql-identifier-quoting-tests \
  Pharos/Utilities/SqlIdentifierQuoting.swift \
  PharosTests/SqlIdentifierQuotingTests.swift \
  PharosTests/main.swift
/tmp/sql-identifier-quoting-tests

#!/bin/bash
# Standalone test runner for SQLLexSnapshot — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/sql-lex-snapshot-tests \
  Pharos/Editor/SQLLexer.swift \
  Pharos/Editor/SQLLexSnapshot.swift \
  Pharos/Editor/SQLSegmentParser.swift \
  PharosTests/SQLLexSnapshotTests.swift \
  PharosTests/main.swift
/tmp/sql-lex-snapshot-tests

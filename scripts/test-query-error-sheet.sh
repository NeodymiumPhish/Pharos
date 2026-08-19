#!/bin/bash
# Standalone test runner for QueryErrorSheet. Uses real AppKit through a headless
# NSWindow, like scripts/test-variable-row-layout.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/query-error-sheet-tests \
  Pharos/Core/SQLErrorLocation.swift \
  Pharos/Models/QueryFailure.swift \
  Pharos/Editor/SQLLexer.swift \
  Pharos/Editor/SQLSyntaxHighlighter.swift \
  Pharos/Views/NSStackView+SpanFullWidth.swift \
  Pharos/Sheets/QueryErrorSheet.swift \
  PharosTests/QueryErrorSheetTests.swift \
  PharosTests/main.swift
/tmp/query-error-sheet-tests

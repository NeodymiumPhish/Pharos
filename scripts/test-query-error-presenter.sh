#!/bin/bash
# Standalone test runner for QueryErrorPresenter — no window, no AppStateManager.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/query-error-presenter-tests \
  Pharos/Core/SQLErrorLocation.swift \
  Pharos/Models/QueryFailure.swift \
  Pharos/Editor/SQLLexer.swift \
  Pharos/Editor/SQLSyntaxHighlighter.swift \
  Pharos/Views/NSStackView+SpanFullWidth.swift \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Editor/FoldState.swift \
  Pharos/Editor/FoldingLayoutManager.swift \
  Pharos/Sheets/QueryErrorSheet.swift \
  Pharos/Core/QueryErrorPresenter.swift \
  PharosTests/QueryErrorPresenterTests.swift \
  PharosTests/main.swift
/tmp/query-error-presenter-tests

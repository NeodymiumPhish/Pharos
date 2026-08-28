#!/bin/bash
# Standalone test runner for the results grid's column-resize handle — no Xcode
# project involvement. The header is a pure view layer; the sort controller and
# its three model files come along only because the header's `sortDirections`
# names `ResultsSortController.SortDirection`.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/grid-column-resize-tests \
  Pharos/ViewControllers/ResultsGrid/FilterableHeaderView.swift \
  Pharos/ViewControllers/ResultsGrid/ResultsSortController.swift \
  Pharos/Models/QueryResult.swift \
  Pharos/Utilities/PGTypeCategory.swift \
  Pharos/Utilities/ColumnIdentifier.swift \
  PharosTests/GridColumnResizeTests.swift \
  PharosTests/main.swift
/tmp/grid-column-resize-tests

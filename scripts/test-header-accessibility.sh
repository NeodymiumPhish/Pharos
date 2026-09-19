#!/bin/bash
# Standalone test runner for the results header's accessibility elements — the
# column titles, their sort state, and the filter funnels, none of which is a
# view. Same file set as scripts/test-grid-column-resize.sh (the header names
# `ResultsSortController.SortDirection`, which drags the sort controller and its
# three model files along) plus the proxy element type.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/header-accessibility-tests \
  Pharos/ViewControllers/ResultsGrid/FilterableHeaderView.swift \
  Pharos/Models/ColumnTypeIcon.swift \
  Pharos/ViewControllers/ResultsGrid/ResultsGridMetrics.swift \
  Pharos/ViewControllers/ResultsGrid/InsetScrollView.swift \
  Pharos/ViewControllers/ResultsGrid/ResultsCellSelection.swift \
  Pharos/ViewControllers/ResultsGrid/ResultsSortController.swift \
  Pharos/Views/AccessibilityProxyElement.swift \
  Pharos/Models/QueryResult.swift \
  Pharos/Utilities/PGTypeCategory.swift \
  Pharos/Utilities/ColumnIdentifier.swift \
  PharosTests/HeaderAccessibilityTests.swift \
  PharosTests/main.swift
/tmp/header-accessibility-tests

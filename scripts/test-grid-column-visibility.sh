#!/bin/bash
# Standalone test runner for hiding and showing result columns from the header's
# context menu — the menu itself, the "never hide the last one" invariant, the
# header geometry a hidden column's zero-width rect would otherwise break, and
# the round trip through `ResultsGridState`.
#
# Same file set as scripts/test-grid-column-resize.sh (the header names
# `ResultsSortController.SortDirection`, which drags the sort controller and its
# model files along) plus `ResultsGridColumnState` and the model tail
# `ResultsGridState` itself reaches through `QueryTab`.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/grid-column-visibility-tests \
  Pharos/ViewControllers/ResultsGrid/FilterableHeaderView.swift \
  Pharos/ViewControllers/ResultsGrid/ResultsGridColumnState.swift \
  Pharos/ViewControllers/ResultsGrid/ResultsGridMetrics.swift \
  Pharos/ViewControllers/ResultsGrid/InsetScrollView.swift \
  Pharos/ViewControllers/ResultsGrid/ResultsCellSelection.swift \
  Pharos/ViewControllers/ResultsGrid/ResultsSortController.swift \
  Pharos/Views/AccessibilityProxyElement.swift \
  Pharos/Core/ResultTabsPanelPrefs.swift \
  Pharos/Core/SQLErrorLocation.swift \
  Pharos/Models/QueryTab.swift \
  Pharos/Models/QueryResult.swift \
  Pharos/Models/QueryFailure.swift \
  Pharos/Models/QueryVariable.swift \
  Pharos/Utilities/ColumnFilter.swift \
  Pharos/Utilities/PGTypeCategory.swift \
  Pharos/Utilities/ColumnIdentifier.swift \
  Pharos/Utilities/BlanksSentinel.swift \
  PharosTests/GridColumnVisibilityTests.swift \
  PharosTests/main.swift
/tmp/grid-column-visibility-tests

#!/bin/bash
# Standalone test runner for ColumnFilterPopoverVC's main-stack geometry. Uses
# real AppKit through a headless NSWindow, like scripts/test-query-error-sheet.sh.
#
# Separate binary from scripts/test-filter-popover-sizing.sh, which tests the
# pure FilterPopoverSizing clamps: only one runTests() can exist per binary.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/filter-popover-layout-tests \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Utilities/BlanksSentinel.swift \
  Pharos/Utilities/PGTypeCategory.swift \
  Pharos/Utilities/ColumnFilter.swift \
  Pharos/ViewControllers/ResultsGrid/FilterValueCount.swift \
  Pharos/ViewControllers/ResultsGrid/FilterValueSort.swift \
  Pharos/ViewControllers/ResultsGrid/FilterPopoverSizing.swift \
  Pharos/ViewControllers/ResultsGrid/FilterValueListView.swift \
  Pharos/ViewControllers/ResultsGrid/FilterCheckRowView.swift \
  Pharos/ViewControllers/ResultsGrid/ResizeGripView.swift \
  Pharos/Views/NSStackView+SpanFullWidth.swift \
  Pharos/ViewControllers/ResultsGrid/ColumnFilterPopoverVC.swift \
  PharosTests/ColumnFilterPopoverLayoutTests.swift \
  PharosTests/main.swift
/tmp/filter-popover-layout-tests

#!/bin/bash
# The chart plots the rows the grid's filters keep (minus the chart's own drill).
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/chart-grid-filters-tests \
  Pharos/Models/QueryResult.swift \
  Pharos/Utilities/SQLTypeName.swift \
  Pharos/Utilities/PGTypeCategory.swift \
  Pharos/Utilities/ColumnFilter.swift \
  Pharos/Utilities/ColumnIdentifier.swift \
  Pharos/Utilities/BlanksSentinel.swift \
  Pharos/Core/TagFunnel.swift \
  Pharos/Core/DisplayRowPipeline.swift \
  Pharos/ViewControllers/ResultsGrid/FilterValueCount.swift \
  Pharos/ViewControllers/ResultsGrid/FilterValueSort.swift \
  Pharos/ViewControllers/ResultsGrid/ResultsColumnFilterController.swift \
  Pharos/Models/Charts/ChartGridFilters.swift \
  PharosTests/ChartGridFiltersTests.swift \
  PharosTests/main.swift
/tmp/chart-grid-filters-tests

#!/bin/bash
# Gantt canvas: lane/bar alignment, wheel scrolling, click selection.
# Needs the window server (shows a borderless window at the screen origin ~1 s).
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/gantt-canvas-tests \
  Pharos/Models/QueryResult.swift \
  Pharos/Utilities/SQLTypeName.swift \
  Pharos/Utilities/BlanksSentinel.swift \
  Pharos/Models/Charts/ChartTypes.swift \
  Pharos/Models/Charts/ChartConfig.swift \
  Pharos/Models/Charts/ChartData.swift \
  Pharos/Models/Charts/ChartAggregator.swift \
  Pharos/Models/Charts/GanttRows.swift \
  Pharos/Models/Charts/ChartAxisTitles.swift \
  Pharos/Models/Charts/ChartPalette.swift \
  Pharos/Models/Charts/ChartPalette+Color.swift \
  Pharos/Models/Charts/ColumnClassifier.swift \
  Pharos/Models/Charts/ValueCoercion.swift \
  Pharos/Models/Charts/DrillKey.swift \
  Pharos/Models/Charts/DrillMerge.swift \
  Pharos/Models/Charts/DrillCoverage.swift \
  Pharos/ViewControllers/Charts/ChartView.swift \
  PharosTests/GanttCanvasTests.swift \
  PharosTests/main.swift
/tmp/gantt-canvas-tests

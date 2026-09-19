#!/bin/bash
# Standalone test runner for what ResultTabBar publishes to a screen reader.
#
# The bar's own file is small; the tail of model files below comes entirely from
# `ResultTab`, which the bar takes as its input and which reaches QueryResult,
# the chart config and the tab-preference types — and, since D5,
# `PendingCellEdits`, which `ResultTab` carries beside its grid state. Nothing
# here is a stub: the suite drives the real bar with a real ResultTab.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/result-tab-bar-accessibility-tests \
  Pharos/Views/ResultTabBar.swift \
  Pharos/Views/ResultTabContextMenu.swift \
  Pharos/Views/ResultTabRowCell.swift \
  Pharos/Views/MarkerShape.swift \
  Pharos/Views/AccessibilityProxyElement.swift \
  Pharos/Core/AccessibilityDisplay.swift \
  Pharos/Core/CountedNounText.swift \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Core/ResultTabName.swift \
  Pharos/Core/ResultTabRowText.swift \
  Pharos/Models/QueryHistoryStatus.swift \
  Pharos/Core/HistoryRowText.swift \
  Pharos/Core/AuthoredLabelSanitizer.swift \
  Pharos/Core/ResultTabsPanelPrefs.swift \
  Pharos/Core/SQLErrorLocation.swift \
  Pharos/Models/PendingCellEdits.swift \
  Pharos/Models/ResultTab.swift \
  Pharos/Models/QueryPlan.swift \
  Pharos/Models/QueryResult.swift \
  Pharos/Models/QueryTab.swift \
  Pharos/Models/QueryFailure.swift \
  Pharos/Models/QueryVariable.swift \
  Pharos/Models/Charts/ChartConfig.swift \
  Pharos/Models/Charts/ChartTypes.swift \
  Pharos/Models/Charts/ColumnClassifier.swift \
  Pharos/Models/Charts/ValueCoercion.swift \
  Pharos/Utilities/ColumnFilter.swift \
  Pharos/Utilities/PGTypeCategory.swift \
  Pharos/Utilities/BlanksSentinel.swift \
  PharosTests/ResultTabBarAccessibilityTests.swift \
  PharosTests/main.swift
/tmp/result-tab-bar-accessibility-tests

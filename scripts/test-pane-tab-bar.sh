#!/bin/bash
# Standalone test runner for PaneTabBar — the editor's tab bar: size-to-fit
# segments, the equal-width fallback, the close slot's three states, tooltips
# and the close proxies' accessibility value.
#
# The bar holds a `WindowSession` weakly for its context menu, so the real
# session comes along with the model tail behind it (the same list as
# scripts/test-window-session.sh); nothing here is a stub.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/pane-tab-bar-tests \
  Pharos/Views/PaneTabBar.swift \
  Pharos/Views/AccessibilityProxyElement.swift \
  Pharos/Core/PulseClock.swift \
  Pharos/Core/WindowSession.swift \
  Pharos/Core/ResultTabsPanelPrefs.swift \
  Pharos/Core/SQLErrorLocation.swift \
  Pharos/Core/CountedNounText.swift \
  Pharos/Models/QueryHistoryStatus.swift \
  Pharos/Core/HistoryRowText.swift \
  Pharos/Core/ResultTabRowText.swift \
  Pharos/Core/ResultTabName.swift \
  Pharos/Core/AuthoredLabelSanitizer.swift \
  Pharos/Views/ResultTabRowCell.swift \
  Pharos/Views/MarkerShape.swift \
  Pharos/Core/AccessibilityDisplay.swift \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Models/ResultTabStore.swift \
  Pharos/Models/ResultTab.swift \
  Pharos/Models/QueryPlan.swift \
  Pharos/Models/Charts/ChartConfig.swift \
  Pharos/Models/Charts/ChartTypes.swift \
  Pharos/Models/PendingCellEdits.swift \
  Pharos/Models/QueryTab.swift \
  Pharos/Models/QueryResult.swift \
  Pharos/Models/QueryFailure.swift \
  Pharos/Models/QueryVariable.swift \
  Pharos/Utilities/ColumnFilter.swift \
  Pharos/Utilities/PGTypeCategory.swift \
  Pharos/Utilities/ColumnIdentifier.swift \
  Pharos/Utilities/BlanksSentinel.swift \
  Pharos/Models/Charts/ColumnClassifier.swift \
  Pharos/Models/Charts/ValueCoercion.swift \
  PharosTests/PaneTabBarTests.swift \
  PharosTests/main.swift
/tmp/pane-tab-bar-tests

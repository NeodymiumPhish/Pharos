#!/bin/bash
# Standalone test runner for RunningQueriesPopoverVC: the running-queries list
# (rows, statement preview, Cancel All). The list reads a real WindowSession,
# so the session's model tail comes along (the list scripts/test-pane-tab-bar.sh
# uses); nothing here is a stub.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/running-queries-popover-tests \
  Pharos/ViewControllers/RunningQueriesPopoverVC.swift \
  Pharos/Utilities/DurationText.swift \
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
  PharosTests/RunningQueriesPopoverTests.swift \
  PharosTests/main.swift
/tmp/running-queries-popover-tests

#!/bin/bash
# Standalone test runner for `WindowSession` — the per-window tab set that used
# to be a global singleton. Tab creation, selection, the three close rules, the
# closed-tab history, connection inheritance and the settled publishers, posed
# against TWO sessions wherever a rule could leak between windows.
#
# `WindowSession` is `@MainActor`, which a harness normally cannot host
# (`main.swift` calls `runTests()` from nonisolated top-level scope). The suite
# wraps its body in `MainActor.assumeIsolated`, which is sound here because the
# binary's main IS the main thread.
#
# `ResultTabStore` and its `ResultTab` come along because the session holds the
# result store; `QueryTab` drags the editor-state model tail behind it.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/window-session-tests \
  Pharos/Core/WindowSession.swift \
  Pharos/Core/ResultTabsPanelPrefs.swift \
  Pharos/Core/SQLErrorLocation.swift \
  Pharos/Core/CountedNounText.swift \
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
  PharosTests/WindowSessionTests.swift \
  PharosTests/main.swift
/tmp/window-session-tests

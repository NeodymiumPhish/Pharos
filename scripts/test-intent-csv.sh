#!/bin/bash
# Standalone test runner for the CSV an App Intent returns — no Xcode project
# involvement.
#
# `IntentResultCSV` is deliberately in its own file, importing Foundation only,
# so this harness can compile it beside ResultsCopyExport without dragging
# AppIntents, AppDelegate and the FFI in behind it. The rest of the file list
# mirrors scripts/test-sql-copy-format.sh, which hosts the same class.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/intent-csv-tests \
  Pharos/Core/TagCopyScope.swift \
  Pharos/Intents/IntentResultCSV.swift \
  Pharos/Models/QueryResult.swift \
  Pharos/Utilities/PGTypeCategory.swift \
  Pharos/Utilities/ColumnIdentifier.swift \
  Pharos/Utilities/SqlIdentifierQuoting.swift \
  Pharos/ViewControllers/ResultsGrid/ResultsCellSelection.swift \
  Pharos/ViewControllers/ResultsGrid/ResultsCopyExport.swift \
  PharosTests/IntentCSVTests.swift \
  PharosTests/main.swift
/tmp/intent-csv-tests

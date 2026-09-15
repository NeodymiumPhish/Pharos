#!/bin/bash
# Standalone test runner for the results grid's drag-out payload (D2): the
# pasteboard types the drag offers, the text behind each of them, and the CSV
# the file promise writes.
#
# ResultsGridVC.swift is deliberately NOT compiled in — it would drag the whole
# app, TagStore and the FFI behind it. The file set mirrors
# scripts/test-sql-copy-format.sh, which hosts the same class.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/drag-pasteboard-tests \
  Pharos/Core/TagCopyScope.swift \
  Pharos/Models/QueryResult.swift \
  Pharos/Utilities/PGTypeCategory.swift \
  Pharos/Utilities/ColumnIdentifier.swift \
  Pharos/Utilities/SqlIdentifierQuoting.swift \
  Pharos/ViewControllers/ResultsGrid/ResultsCellSelection.swift \
  Pharos/ViewControllers/ResultsGrid/ResultsCopyExport.swift \
  PharosTests/DragPasteboardTests.swift \
  PharosTests/main.swift
/tmp/drag-pasteboard-tests

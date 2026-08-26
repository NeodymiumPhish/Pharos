#!/bin/bash
# Standalone test runner for the SQL text of "Copy as SQL WITH" / "Copy as SQL
# INSERT" — no Xcode project involvement.
#
# ResultsGridVC.swift is deliberately NOT compiled in — it would drag the whole
# app, TagStore and the FFI behind it. The file set mirrors
# scripts/test-tag-copy-export.sh, which hosts the same class.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/sql-copy-format-tests \
  Pharos/Core/TagCopyScope.swift \
  Pharos/Models/QueryResult.swift \
  Pharos/Utilities/PGTypeCategory.swift \
  Pharos/Utilities/ColumnIdentifier.swift \
  Pharos/Utilities/SqlIdentifierQuoting.swift \
  Pharos/ViewControllers/ResultsGrid/ResultsCellSelection.swift \
  Pharos/ViewControllers/ResultsGrid/ResultsCopyExport.swift \
  PharosTests/SQLCopyFormatTests.swift \
  PharosTests/main.swift
/tmp/sql-copy-format-tests

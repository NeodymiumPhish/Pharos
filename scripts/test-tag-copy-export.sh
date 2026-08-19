#!/bin/bash
# Standalone test runner for the tagged-rows-only copy/export scope AS WIRED
# into ResultsCopyExport. Uses real AppKit through a headless NSTableView, like
# scripts/test-tag-removal-sheet.sh hosts the real sheet.
#
# scripts/test-tag-copy-scope.sh covers the pure rule; this covers the call
# sites, where the rule can be handed a display index instead of a data one, or
# the summary can stop mirroring the gather, with nothing else noticing.
#
# ResultsGridVC.swift is deliberately NOT compiled in — it would drag the whole
# app, TagStore and the FFI behind it. ColumnIdentifier.swift exists so the one
# global ResultsCopyExport needs from that side can be linked for real instead
# of copied into the test file, where it would rot.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/tag-copy-export-tests \
  Pharos/Core/TagCopyScope.swift \
  Pharos/Models/QueryResult.swift \
  Pharos/Utilities/PGTypeCategory.swift \
  Pharos/Utilities/ColumnIdentifier.swift \
  Pharos/Utilities/SqlIdentifierQuoting.swift \
  Pharos/ViewControllers/ResultsGrid/ResultsCellSelection.swift \
  Pharos/ViewControllers/ResultsGrid/ResultsCopyExport.swift \
  PharosTests/TagCopyExportTests.swift \
  PharosTests/main.swift
/tmp/tag-copy-export-tests

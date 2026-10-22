#!/bin/bash
# D3: a data file dropped on the Database Navigator, through a stand-in
# NSDraggingInfo: import onto a table, a new table elsewhere, refusals.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$(mktemp -t navigator-file-drop-tests)"
trap 'rm -f "$BIN"' EXIT
swiftc -o "$BIN" \
  Pharos/ViewControllers/SchemaBrowser/SchemaDataSource.swift \
  Pharos/Views/SchemaTreeCellView.swift \
  Pharos/Models/SchemaTreeNode.swift \
  Pharos/Models/Schema.swift \
  Pharos/Models/Settings.swift \
  Pharos/Models/Charts/ChartPalette.swift \
  Pharos/Models/PartitionDisplay.swift \
  Pharos/Utilities/SQLTypeName.swift \
  Pharos/Models/ColumnTypeIcon.swift \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Core/DataFiles.swift \
  PharosTests/NavigatorFileDropTests.swift \
  PharosTests/main.swift
"$BIN"

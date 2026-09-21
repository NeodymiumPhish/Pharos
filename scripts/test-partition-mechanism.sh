#!/bin/bash
# Standalone test runner for the display decisions that legacy inheritance
# partitioning changes: the Partitions-folder rule on TableInfo, and the
# INHERITS badge on SchemaTreeNode. Real AppKit, headless — the cell is laid
# out by hand, so no window is needed.
#
# SchemaBrowserVC is excluded: it pulls in the PharosCore FFI bridge, which
# cannot link in a plain swiftc binary.
#
# The binary name is unique to this suite: every test-*.sh writes a fixed
# path, and two suites sharing one would clobber each other when run
# concurrently.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/partition-mechanism-tests \
  Pharos/Views/SchemaTreeCellView.swift \
  Pharos/Models/SchemaTreeNode.swift \
  Pharos/Models/Schema.swift \
  Pharos/Models/Settings.swift \
  Pharos/Models/Charts/ChartPalette.swift \
  Pharos/Models/PartitionDisplay.swift \
  Pharos/Models/ColumnTypeIcon.swift \
  Pharos/Core/DisplayEscape.swift \
  PharosTests/PartitionMechanismTests.swift \
  PharosTests/main.swift
/tmp/partition-mechanism-tests

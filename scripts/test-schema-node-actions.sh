#!/bin/bash
# Standalone test runner for the rule that decides which table actions a row
# inside the Navigator's "Partitions" folder offers: TableInfo.partitionRole
# and .offersFullTableActions in Pharos/Models/Schema.swift.
#
# SchemaContextMenu is NOT compiled here — it needs an NSOutlineView with a
# clicked row and the PharosCore FFI bridge, neither of which links in a plain
# swiftc binary. That is why the rule lives on the model: it is the part worth
# testing, and `menuNeedsUpdate` is a two-line switch over it.
#
# Settings.swift and ChartPalette.swift come along because Schema.swift does
# not compile without them, as in the other harnesses that include it.
#
# The binary goes in a fresh mktemp dir, NOT a fixed /tmp name: the older
# scripts share those, so two concurrent sweeps clobber each other.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN=$(mktemp -d)/schema-node-actions-tests
swiftc -o "$BIN" \
  Pharos/Models/Charts/ChartPalette.swift \
  Pharos/Models/Schema.swift \
  Pharos/Models/Settings.swift \
  PharosTests/SchemaNodeActionsTests.swift \
  PharosTests/main.swift
"$BIN"

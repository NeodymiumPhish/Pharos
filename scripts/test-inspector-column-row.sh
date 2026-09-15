#!/bin/bash
# Standalone test runner for the Inspector's Columns-section row. Real AppKit,
# headless: layout and the pasteboard need no window.
#
# InspectorViewController itself is excluded — it pulls in the PharosCore FFI
# bridge, which cannot link in a plain swiftc binary; the row lives in its own
# file for exactly that reason.
#
# The binary name is unique to this suite: every test-*.sh writes a fixed path,
# and two suites sharing one would clobber each other when run concurrently.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/inspector-column-row-tests \
  Pharos/Views/InspectorColumnRowView.swift \
  Pharos/Models/Schema.swift \
  Pharos/Utilities/SqlIdentifierQuoting.swift \
  Pharos/Core/DisplayEscape.swift \
  PharosTests/InspectorColumnRowTests.swift \
  PharosTests/main.swift
/tmp/inspector-column-row-tests

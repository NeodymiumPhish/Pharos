#!/bin/bash
# Standalone test runner for SavedQueryCellView. Real AppKit, headless: the
# cell is hosted in a never-shown NSWindow, because the field editor these
# tests read is the window's to give.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/saved-query-cell-view-tests \
  Pharos/Views/SavedQueryCellView.swift \
  Pharos/Views/NSTextField+AuthoredLabel.swift \
  Pharos/Core/AuthoredLabelSanitizer.swift \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Core/SanitiseNotice.swift \
  Pharos/Views/Toast.swift \
  PharosTests/SavedQueryCellViewTests.swift \
  PharosTests/main.swift
/tmp/saved-query-cell-view-tests

#!/bin/bash
# Standalone test runner for the results cell's dimmed marks (tier B of
# DisplayEscape, Settings ▸ Results ▸ Cells ▸ Show invisible characters).
# Renders offscreen into an NSBitmapImageRep and reads the ink — no window on
# screen, no Screen Recording permission, no Accessibility.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/result-cell-marks-tests \
  Pharos/Core/DisplayEscape.swift \
  Pharos/ViewControllers/ResultsGrid/ResultCellView.swift \
  PharosTests/ResultCellMarksTests.swift \
  PharosTests/main.swift
/tmp/result-cell-marks-tests

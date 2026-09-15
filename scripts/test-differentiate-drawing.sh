#!/bin/bash
# Standalone test runner for what Differentiate Without Color paints: the eight
# markers and the tag bar's per-band hatch, rendered offscreen into an
# NSBitmapImageRep and compared as greyscale masks. No window, no screenshot
# API, no permissions.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/differentiate-drawing-tests \
  Pharos/Core/AccessibilityDisplay.swift \
  Pharos/Views/MarkerShape.swift \
  Pharos/ViewControllers/ResultsGrid/TaggedRowView.swift \
  PharosTests/DifferentiateDrawingTests.swift \
  PharosTests/main.swift
/tmp/differentiate-drawing-tests

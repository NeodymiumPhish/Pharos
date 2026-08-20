#!/bin/bash
# Standalone test runner for what hostile-scalar pills actually PAINT.
# Renders offscreen into an NSBitmapImageRep and counts ink. This is not screen
# capture — no window, no Screen Recording permission, no Accessibility.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/hostile-text-pixel-tests \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Editor/FoldState.swift \
  Pharos/Editor/FoldingLayoutManager.swift \
  PharosTests/HostileTextPixelTests.swift \
  PharosTests/main.swift
/tmp/hostile-text-pixel-tests

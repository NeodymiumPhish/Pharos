#!/bin/bash
# Standalone test runner for hostile-scalar disclosure in FoldingLayoutManager.
# Exercises real AppKit text layout: glyph positions inside a real NSTextView.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/hostile-text-rendering-tests \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Editor/FoldState.swift \
  Pharos/Editor/FoldingLayoutManager.swift \
  PharosTests/HostileTextRenderingTests.swift \
  PharosTests/main.swift
/tmp/hostile-text-rendering-tests

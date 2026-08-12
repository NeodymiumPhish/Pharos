#!/bin/bash
# Standalone test runner for TagLabelPalette. Pure AppKit + Foundation, headless.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/tag-appearance-tests \
  Pharos/Core/TagLabelPalette.swift \
  Pharos/Models/RowTag.swift \
  PharosTests/TagAppearanceTests.swift \
  PharosTests/main.swift
/tmp/tag-appearance-tests

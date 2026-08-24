#!/bin/bash
# Standalone test runner for TagPalette. Pure AppKit + Foundation, headless.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/tag-appearance-tests \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Core/TagPalette.swift \
  Pharos/ViewControllers/ResultsGrid/FindMatchDecoration.swift \
  Pharos/Core/TagRuleMatcher.swift \
  Pharos/Core/TagValueNormalizer.swift \
  Pharos/Core/CIDRRange.swift \
  Pharos/Core/RowFingerprint.swift \
  Pharos/Models/Tag.swift \
  Pharos/Models/QueryResult.swift \
  PharosTests/TagAppearanceTests.swift \
  PharosTests/main.swift
/tmp/tag-appearance-tests

#!/bin/bash
# Standalone test runner for TagRemovalModel. Pure Foundation, no AppKit.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/tag-removal-model-tests \
  Pharos/Core/TagRemovalModel.swift \
  Pharos/Core/TagMatchDisclosure.swift \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Core/TagTupleMatcher.swift \
  Pharos/Core/TagValueNormalizer.swift \
  Pharos/Core/CIDRRange.swift \
  Pharos/Models/Tag.swift \
  Pharos/Models/QueryResult.swift \
  PharosTests/TagRemovalModelTests.swift \
  PharosTests/main.swift
/tmp/tag-removal-model-tests

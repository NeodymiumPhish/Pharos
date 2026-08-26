#!/bin/bash
# Standalone test runner for TagRemovalModel. Pure Foundation, no AppKit.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/tag-removal-model-tests \
  Pharos/Core/TagRemovalModel.swift \
  Pharos/Core/TagMatchDisclosure.swift \
  Pharos/Core/TagFamilyLabel.swift \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Core/TagRuleMatcher.swift \
  Pharos/Core/TagValueNormalizer.swift \
  Pharos/Core/CIDRRange.swift \
  Pharos/Core/TagConditionKind.swift \
  Pharos/Core/TagGlob.swift \
  Pharos/Core/TagPredicate.swift \
  Pharos/Models/Tag.swift \
  Pharos/Models/QueryResult.swift \
  PharosTests/TagRemovalModelTests.swift \
  PharosTests/main.swift
/tmp/tag-removal-model-tests

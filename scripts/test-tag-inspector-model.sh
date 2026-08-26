#!/bin/bash
# Standalone test runner for TagInspectorModel. Pure Foundation, no AppKit.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/tag-inspector-model-tests \
  Pharos/Core/TagInspectorModel.swift \
  Pharos/Core/TagMatchDisclosure.swift \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Core/TagRuleMatcher.swift \
  Pharos/Core/TagValueNormalizer.swift \
  Pharos/Core/CIDRRange.swift \
  Pharos/Core/TagConditionKind.swift \
  Pharos/Core/TagGlob.swift \
  Pharos/Core/TagPredicate.swift \
  Pharos/Models/Tag.swift \
  Pharos/Models/QueryResult.swift \
  PharosTests/TagInspectorModelTests.swift \
  PharosTests/main.swift
/tmp/tag-inspector-model-tests

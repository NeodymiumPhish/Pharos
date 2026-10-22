#!/bin/bash
# Standalone test runner for TagSampleTest: which of a tag's rules a typed
# sample value satisfies, through the matcher's own normalizer and predicates.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/tag-sample-test-tests \
  Pharos/Core/TagSampleTest.swift \
  Pharos/Core/TagPredicate.swift \
  Pharos/Core/TagGlob.swift \
  Pharos/Core/TagConditionKind.swift \
  Pharos/Core/TagValueNormalizer.swift \
  Pharos/Core/CIDRRange.swift \
  Pharos/Utilities/SQLTypeName.swift \
  Pharos/Models/Tag.swift \
  PharosTests/TagSampleTestTests.swift \
  PharosTests/main.swift
/tmp/tag-sample-test-tests

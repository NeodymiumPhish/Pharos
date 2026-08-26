#!/bin/bash
# Standalone runner for TagConditionKind and TagPredicate. Foundation + Darwin
# only — CIDRRange calls inet_pton/inet_ntop directly, and nothing here imports
# AppKit.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/tag-predicate-tests \
  Pharos/Core/TagConditionKind.swift \
  Pharos/Core/CIDRRange.swift \
  Pharos/Core/TagGlob.swift \
  Pharos/Core/TagValueNormalizer.swift \
  Pharos/Models/Tag.swift \
  Pharos/Core/TagPredicate.swift \
  PharosTests/TagPredicateTests.swift \
  PharosTests/main.swift
/tmp/tag-predicate-tests

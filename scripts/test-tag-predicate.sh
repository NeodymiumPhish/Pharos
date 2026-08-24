#!/bin/bash
# Standalone runner for TagConditionKind, and later TagPredicate. Foundation
# only for now — the kind depends on nothing.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/tag-predicate-tests \
  Pharos/Core/TagConditionKind.swift \
  PharosTests/TagPredicateTests.swift \
  PharosTests/main.swift
/tmp/tag-predicate-tests

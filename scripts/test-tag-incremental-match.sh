#!/bin/bash
# Standalone runner: a Load More page matched alone and merged with
# TagRuleMatcher.appendingPage equals matching every row. Pure Foundation.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/tag-incremental-match-tests \
  Pharos/Core/RowFingerprint.swift \
  Pharos/Core/CIDRRange.swift \
  Pharos/Utilities/SQLTypeName.swift \
  Pharos/Core/TagValueNormalizer.swift \
  Pharos/Core/RuleKey.swift \
  Pharos/Core/TagRuleMatcher.swift \
  Pharos/Core/TagRowMatch.swift \
  Pharos/Core/TagConditionKind.swift \
  Pharos/Core/TagGlob.swift \
  Pharos/Core/TagPredicate.swift \
  Pharos/Models/Tag.swift \
  Pharos/Models/QueryResult.swift \
  PharosTests/TagIncrementalMatchTests.swift \
  PharosTests/main.swift
/tmp/tag-incremental-match-tests

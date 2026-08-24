#!/bin/bash
# Standalone runner for TagRuleMatcher. Pure Foundation — the matcher, the
# normalizer and CIDRRange it calls, the key encoder, and the tag models.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/tag-tuple-matcher-tests \
  Pharos/Core/RowFingerprint.swift \
  Pharos/Core/CIDRRange.swift \
  Pharos/Core/TagValueNormalizer.swift \
  Pharos/Core/RuleKey.swift \
  Pharos/Core/TagRuleMatcher.swift \
  Pharos/Models/Tag.swift \
  Pharos/Models/QueryResult.swift \
  PharosTests/TagTupleMatcherTests.swift \
  PharosTests/main.swift
/tmp/tag-tuple-matcher-tests

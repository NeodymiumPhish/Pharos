#!/bin/bash
# Standalone runner for TagDraft — the capture rules the modal applies and the
# live count it shows. Pure Foundation.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/tag-draft-tests \
  Pharos/Core/RowFingerprint.swift \
  Pharos/Core/CIDRRange.swift \
  Pharos/Core/TagValueNormalizer.swift \
  Pharos/Core/RuleKey.swift \
  Pharos/Core/TagRuleMatcher.swift \
  Pharos/Core/TagDraft.swift \
  Pharos/Core/TagConditionKind.swift \
  Pharos/Core/TagGlob.swift \
  Pharos/Core/TagPredicate.swift \
  Pharos/Models/Tag.swift \
  Pharos/Models/QueryResult.swift \
  PharosTests/TagDraftTests.swift \
  PharosTests/main.swift
/tmp/tag-draft-tests

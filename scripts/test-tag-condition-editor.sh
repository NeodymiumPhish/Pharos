#!/bin/bash
# Standalone runner for TagConditionEditor. Pulls in TagPredicate and its
# dependencies because the suite proves the operator lists agree with what the
# matcher can actually compile — a second list would drift.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/tag-condition-editor-tests \
  Pharos/Core/TagConditionEditor.swift \
  Pharos/Core/TagConditionKind.swift \
  Pharos/Core/TagPredicate.swift \
  Pharos/Core/TagGlob.swift \
  Pharos/Core/CIDRRange.swift \
  Pharos/Core/TagValueNormalizer.swift \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Models/Tag.swift \
  PharosTests/TagConditionEditorTests.swift \
  PharosTests/main.swift
/tmp/tag-condition-editor-tests

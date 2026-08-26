#!/bin/bash
# Standalone runner for TagManagerModel. Foundation only — the model holds no
# AppKit and reaches no store, which is what lets this suite pin every decision
# the Tag Manager makes before any of its UI exists.
set -euo pipefail
cd "$(dirname "$0")/.."
#
# AuthoredLabelSanitizer comes along because the name a save writes is
# sanitised and then trimmed at the commit — see `committedName`.
swiftc -o /tmp/tag-manager-model-tests \
  Pharos/Core/AuthoredLabelSanitizer.swift \
  Pharos/Core/TagManagerModel.swift \
  Pharos/Core/TagCapture.swift \
  Pharos/Core/TagDraft.swift \
  Pharos/Core/TagFamilyLabel.swift \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Core/TagConditionKind.swift \
  Pharos/Core/TagValueNormalizer.swift \
  Pharos/Core/CIDRRange.swift \
  Pharos/Core/RuleKey.swift \
  Pharos/Core/RowFingerprint.swift \
  Pharos/Models/Tag.swift \
  Pharos/Models/QueryResult.swift \
  PharosTests/TagManagerModelTests.swift \
  PharosTests/main.swift
/tmp/tag-manager-model-tests

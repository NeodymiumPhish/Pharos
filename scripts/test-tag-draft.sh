#!/bin/bash
# Standalone runner for TagDraft — the capture rules the modal applies and the
# live count it shows. Pure Foundation.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/tag-draft-tests \
  Pharos/Core/RowFingerprint.swift \
  Pharos/Core/CIDRRange.swift \
  Pharos/Core/TagValueNormalizer.swift \
  Pharos/Core/TupleKey.swift \
  Pharos/Core/TagTupleMatcher.swift \
  Pharos/Core/TagDraft.swift \
  Pharos/Models/Tag.swift \
  Pharos/Models/QueryResult.swift \
  PharosTests/TagDraftTests.swift \
  PharosTests/main.swift
/tmp/tag-draft-tests

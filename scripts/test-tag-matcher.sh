#!/bin/bash
# Standalone test runner for TagMatcher. Pure Foundation — the matcher, the two
# model files it reads, and the fingerprint encoder it calls on the weak path.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/tag-matcher-tests \
  Pharos/Core/RowFingerprint.swift \
  Pharos/Core/TagMatcher.swift \
  Pharos/Models/RowTag.swift \
  Pharos/Models/QueryResult.swift \
  Pharos/Models/QueryHistory.swift \
  PharosTests/TagMatcherTests.swift \
  PharosTests/main.swift
/tmp/tag-matcher-tests

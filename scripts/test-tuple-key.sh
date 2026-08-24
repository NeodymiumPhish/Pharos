#!/bin/bash
# Standalone runner for RuleKey. Foundation only — it reuses RowFingerprint's
# length-prefixed field grammar, so both files compile in.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/tuple-key-tests \
  Pharos/Core/RowFingerprint.swift \
  Pharos/Core/TagValueNormalizer.swift \
  Pharos/Core/CIDRRange.swift \
  Pharos/Core/RuleKey.swift \
  PharosTests/TupleKeyTests.swift \
  PharosTests/main.swift
/tmp/tuple-key-tests

#!/bin/bash
# Standalone test runner for TagComposer. Pure Foundation, no AppKit.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/tag-composer-tests \
  Pharos/Core/RowFingerprint.swift \
  Pharos/Core/TagComposer.swift \
  Pharos/Models/RowTag.swift \
  Pharos/Models/QueryResult.swift \
  PharosTests/TagComposerTests.swift \
  PharosTests/main.swift
/tmp/tag-composer-tests

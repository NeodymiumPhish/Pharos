#!/bin/bash
# Standalone test runner for SessionSnapshot — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/pharos-session-snapshot-tests \
  Pharos/Models/CardDocument.swift \
  Pharos/Models/QueryResult.swift \
  Pharos/Models/SavedQuery.swift \
  Pharos/Core/Cards/SessionSnapshot.swift \
  PharosTests/SessionSnapshotTests.swift \
  PharosTests/main.swift
/tmp/pharos-session-snapshot-tests

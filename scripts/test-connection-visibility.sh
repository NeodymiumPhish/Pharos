#!/bin/bash
# Standalone test runner for ConnectionVisibility: which connection records
# each list shows (saved vs opened-only), the tab pop-up's groups, and the
# Connections Manager's reorder merge.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/connection-visibility-tests \
  Pharos/Core/ConnectionVisibility.swift \
  Pharos/Models/Connection.swift \
  PharosTests/ConnectionVisibilityTests.swift \
  PharosTests/main.swift
/tmp/connection-visibility-tests

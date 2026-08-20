#!/bin/bash
# Standalone test runner for SavedQueryFilename. Pure Foundation.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/saved-query-filename-tests \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Files/SavedQueryFilename.swift \
  PharosTests/SavedQueryFilenameTests.swift \
  PharosTests/main.swift
/tmp/saved-query-filename-tests

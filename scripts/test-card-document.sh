#!/bin/bash
# Standalone test runner for CardDocument — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/pharos-card-document-tests \
  Pharos/Models/CardDocument.swift \
  PharosTests/CardDocumentTests.swift \
  PharosTests/main.swift
/tmp/pharos-card-document-tests

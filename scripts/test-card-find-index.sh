#!/bin/bash
# Standalone test runner for CardFindIndex — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/pharos-card-find-index-tests \
  Pharos/Core/Cards/CardFindIndex.swift \
  PharosTests/CardFindIndexTests.swift \
  PharosTests/main.swift
/tmp/pharos-card-find-index-tests

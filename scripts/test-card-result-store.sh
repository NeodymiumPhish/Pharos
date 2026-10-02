#!/bin/bash
# Standalone test runner for CardResultEviction — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/pharos-card-result-store-tests \
  Pharos/Core/Cards/CardResultEviction.swift \
  PharosTests/CardResultStoreTests.swift \
  PharosTests/main.swift
/tmp/pharos-card-result-store-tests

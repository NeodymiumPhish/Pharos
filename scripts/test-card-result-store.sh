#!/bin/bash
# Standalone test runner for CardKeyedStore and CardResultEviction — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/pharos-card-result-store-tests \
  Pharos/Core/Cards/CardKeyedStore.swift \
  PharosTests/CardResultStoreTests.swift \
  PharosTests/main.swift
/tmp/pharos-card-result-store-tests

#!/bin/bash
# Standalone test runner for CardStackLayout — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/pharos-card-stack-layout-tests \
  Pharos/Models/CardDocument.swift \
  Pharos/Core/Cards/CardStackLayout.swift \
  PharosTests/CardStackLayoutTests.swift \
  PharosTests/main.swift
/tmp/pharos-card-stack-layout-tests

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/quick-look-item-builder-tests \
  Pharos/Utilities/QuickLookItemBuilder.swift \
  PharosTests/QuickLookItemBuilderTests.swift \
  PharosTests/main.swift
/tmp/quick-look-item-builder-tests

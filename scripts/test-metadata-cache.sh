#!/bin/bash
# Standalone test runner for MetadataCache with a fake loader — no Rust core,
# no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/pharos-metadata-cache-tests \
  Pharos/Core/MetadataCache.swift \
  Pharos/Core/Log.swift \
  Pharos/Models/Schema.swift \
  Pharos/Models/Settings.swift \
  Pharos/Models/Charts/ChartPalette.swift \
  PharosTests/MetadataCacheTests.swift \
  PharosTests/main.swift
/tmp/pharos-metadata-cache-tests

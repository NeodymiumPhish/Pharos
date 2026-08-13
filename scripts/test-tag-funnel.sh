#!/bin/bash
# Standalone test runner for TagFunnel. Pure Foundation, no AppKit.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/tag-funnel-tests \
  Pharos/Core/TagFunnel.swift \
  Pharos/Utilities/ColumnFilter.swift \
  Pharos/Utilities/BlanksSentinel.swift \
  Pharos/Utilities/PGTypeCategory.swift \
  PharosTests/TagFunnelTests.swift \
  PharosTests/main.swift
/tmp/tag-funnel-tests

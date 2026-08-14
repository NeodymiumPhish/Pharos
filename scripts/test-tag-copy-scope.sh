#!/bin/bash
# Standalone test runner for TagCopyScope. Pure Foundation, no AppKit.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/tag-copy-scope-tests \
  Pharos/Core/TagCopyScope.swift \
  PharosTests/TagCopyScopeTests.swift \
  PharosTests/main.swift
/tmp/tag-copy-scope-tests

#!/bin/bash
# Standalone test runner for ResultTabResolver — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/result-tab-resolver-tests \
  Pharos/Editor/SQLLexer.swift \
  Pharos/Editor/SQLSegmentParser.swift \
  Pharos/ViewControllers/ResultTabResolver.swift \
  PharosTests/ResultTabResolverTests.swift \
  PharosTests/main.swift
/tmp/result-tab-resolver-tests

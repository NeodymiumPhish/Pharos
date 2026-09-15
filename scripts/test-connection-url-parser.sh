#!/bin/bash
# Standalone test runner for ConnectionURLParser (the postgres:// link reader).
# Foundation only — the parser has no AppKit or FFI dependency.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/connection-url-parser-tests \
  Pharos/Utilities/ConnectionURLParser.swift \
  PharosTests/ConnectionURLParserTests.swift \
  PharosTests/main.swift
/tmp/connection-url-parser-tests

#!/bin/bash
# Standalone test runner for SchemaListFilter — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/schema-list-filter-tests \
  Pharos/Editor/SchemaListFilter.swift \
  PharosTests/SchemaListFilterTests.swift \
  PharosTests/main.swift
/tmp/schema-list-filter-tests

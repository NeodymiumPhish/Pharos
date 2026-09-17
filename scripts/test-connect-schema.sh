#!/bin/bash
# Standalone test runner for ConnectSchema: the schema a connect lands on —
# the tab's own first, then the configured default, the window's memory, public.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/connect-schema-tests \
  Pharos/Core/ConnectSchema.swift \
  PharosTests/ConnectSchemaTests.swift \
  PharosTests/main.swift
/tmp/connect-schema-tests

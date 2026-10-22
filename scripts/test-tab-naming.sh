#!/bin/bash
# Standalone test runner for TabNaming: "New Tab N" for a tab with no
# connection, "{connection} - {schema}" once it has one, and the " (2)" that
# tells two tabs on one connection and schema apart.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/tab-naming-tests \
  Pharos/Core/TabNaming.swift \
  PharosTests/TabNamingTests.swift \
  PharosTests/main.swift
/tmp/tab-naming-tests

#!/bin/bash
# Standalone test runner for RunScopeResolver: what Cmd+Return runs under each
# of the three scopes, including the whitespace-only selection that must fall
# back to the statement rather than run nothing.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/run-scope-resolver-tests \
  Pharos/Core/RunScopeResolver.swift \
  Pharos/Models/Settings.swift \
  Pharos/Models/Charts/ChartPalette.swift \
  PharosTests/RunScopeResolverTests.swift \
  PharosTests/main.swift
/tmp/run-scope-resolver-tests

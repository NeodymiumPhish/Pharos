#!/bin/bash
# Standalone test runner for EditorReloadRule: where an open inline editor goes
# when the results grid reloads under it. Pure Foundation, no AppKit.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/editor-reload-rule-tests \
  Pharos/ViewControllers/ResultsGrid/EditorReloadRule.swift \
  PharosTests/EditorReloadRuleTests.swift \
  PharosTests/main.swift
/tmp/editor-reload-rule-tests

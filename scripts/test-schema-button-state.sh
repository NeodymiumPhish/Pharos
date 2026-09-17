#!/bin/bash
# Standalone test runner for SchemaButtonState: the toolbar schema pull-down's
# title, enabled state and spinner, per tab state. DisplayEscape comes along
# for the title's escaping.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/schema-button-state-tests \
  Pharos/Core/SchemaButtonState.swift \
  Pharos/Core/DisplayEscape.swift \
  PharosTests/SchemaButtonStateTests.swift \
  PharosTests/main.swift
/tmp/schema-button-state-tests

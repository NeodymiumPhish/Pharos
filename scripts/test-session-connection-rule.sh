#!/bin/bash
# Standalone test runner for SessionConnectionRule: a saved Session opens on
# its own connection, or on none — never on the tab it was opened from.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/session-connection-rule-tests \
  Pharos/Core/SessionConnectionRule.swift \
  PharosTests/SessionConnectionRuleTests.swift \
  PharosTests/main.swift
/tmp/session-connection-rule-tests

#!/bin/bash
# Standalone test runner for ScrollBarPolicy: the "Always show scroll bars"
# rule as a pure function, and the live object that follows the setting and
# the system's scroll-bar preference.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/scroll-bar-policy-tests \
  Pharos/Views/ScrollBarPolicy.swift \
  PharosTests/ScrollBarPolicyTests.swift \
  PharosTests/main.swift
/tmp/scroll-bar-policy-tests

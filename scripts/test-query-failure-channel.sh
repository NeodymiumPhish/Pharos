#!/bin/bash
# Standalone test runner for QueryFailureChannel — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/query-failure-channel-tests \
  Pharos/Core/QueryFailureChannel.swift \
  PharosTests/QueryFailureChannelTests.swift \
  PharosTests/main.swift
/tmp/query-failure-channel-tests

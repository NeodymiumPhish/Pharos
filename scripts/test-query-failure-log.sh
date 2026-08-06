#!/bin/bash
# Standalone test runner for QueryFailure / QueryFailureLog — no Xcode project.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/query-failure-log-tests \
  Pharos/Core/SQLErrorLocation.swift \
  Pharos/Models/QueryFailure.swift \
  PharosTests/QueryFailureLogTests.swift \
  PharosTests/main.swift
/tmp/query-failure-log-tests

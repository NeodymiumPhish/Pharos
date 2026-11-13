#!/bin/bash
# Standalone test runner for the custom AI endpoint's address rules, the
# reading of its "list the models" answer (Settings ▸ Intelligence), and the
# words that name the model to the user (IntelligenceSource).
# Foundation only; nothing is sent anywhere.
set -euo pipefail
cd "$(dirname "$0")/.."
bin=/tmp/pharos-intelligence-endpoint-tests
swiftc -o "$bin" \
  Pharos/Intelligence/IntelligenceEndpoint.swift \
  Pharos/Intelligence/IntelligenceSource.swift \
  PharosTests/IntelligenceEndpointTests.swift \
  PharosTests/main.swift
"$bin"

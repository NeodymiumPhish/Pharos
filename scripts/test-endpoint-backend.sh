#!/bin/bash
# Standalone test runner for EndpointIntelligenceBackend, the client for a
# custom AI endpoint: the request it builds, how it reads an answer, how it
# steps down when an endpoint refuses a way of asking for JSON, and what
# each failure becomes. The transport is a stand-in; nothing is sent.
set -euo pipefail
cd "$(dirname "$0")/.."
bin=/tmp/pharos-endpoint-backend-tests
swiftc -o "$bin" \
  Pharos/Intelligence/IntelligenceEndpoint.swift \
  Pharos/Intelligence/IntelligenceBackend.swift \
  Pharos/Intelligence/ModelErrorKind.swift \
  Pharos/Intelligence/EndpointIntelligenceBackend.swift \
  PharosTests/EndpointBackendTests.swift \
  PharosTests/main.swift
"$bin"

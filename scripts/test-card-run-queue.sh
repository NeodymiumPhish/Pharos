#!/bin/bash
# Standalone test runner for CardRunQueue — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/pharos-card-run-queue-tests \
  Pharos/Models/CardDocument.swift \
  Pharos/Core/Cards/CardRunQueue.swift \
  PharosTests/CardRunQueueTests.swift \
  PharosTests/main.swift
/tmp/pharos-card-run-queue-tests

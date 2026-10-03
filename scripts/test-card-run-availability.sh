#!/bin/bash
# Standalone test runner for CardRunAvailability — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/pharos-card-run-availability-tests \
  Pharos/Models/Connection.swift \
  Pharos/Core/Cards/CardRunAvailability.swift \
  PharosTests/CardRunAvailabilityTests.swift \
  PharosTests/main.swift
/tmp/pharos-card-run-availability-tests

#!/bin/bash
# Standalone test runner for PasswordAvailability — the rule that decides
# whether a connect attempt dials with the password it has, asks the user for
# one, or refuses. All sixteen combinations of its four inputs.
# No Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$(mktemp -t password-availability-tests)"
trap 'rm -f "$BIN"' EXIT
swiftc -o "$BIN" \
  Pharos/Core/PasswordAvailability.swift \
  PharosTests/PasswordAvailabilityTests.swift \
  PharosTests/main.swift
"$BIN"

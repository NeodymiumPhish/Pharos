#!/bin/bash
# Standalone test runner for DestructiveConfirmationText. Pure Foundation.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/destructive-confirmation-text-tests \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Core/DestructiveConfirmationText.swift \
  PharosTests/DestructiveConfirmationTextTests.swift \
  PharosTests/main.swift
/tmp/destructive-confirmation-text-tests

#!/bin/bash
# Standalone test runner for AuthoredLabelTextField. Drives a real field editor
# in a headless (never-shown) window, so the delegate wiring is exercised
# rather than assumed.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/authored-label-field-tests \
  Pharos/Core/AuthoredLabelSanitizer.swift \
  Pharos/Views/NSTextField+AuthoredLabel.swift \
  Pharos/Views/AuthoredLabelTextField.swift \
  PharosTests/AuthoredLabelTextFieldTests.swift \
  PharosTests/main.swift
/tmp/authored-label-field-tests

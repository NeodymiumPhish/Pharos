#!/bin/bash
# Standalone test runner for SanitiseNotice. Pure Foundation.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/sanitise-notice-tests \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Core/AuthoredLabelSanitizer.swift \
  Pharos/Core/SanitiseNotice.swift \
  PharosTests/SanitiseNoticeTests.swift \
  PharosTests/main.swift
/tmp/sanitise-notice-tests

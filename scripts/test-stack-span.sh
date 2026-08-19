#!/bin/bash
# Standalone test runner for NSStackView.spanArrangedSubviewsFullWidth. Uses
# real AppKit through a laid-out view, like scripts/test-tag-removal-sheet.sh:
# the point of the helper is a measured geometry, so the assertions measure.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/stack-span-tests \
  Pharos/Views/NSStackView+SpanFullWidth.swift \
  PharosTests/StackSpanTests.swift \
  PharosTests/main.swift
/tmp/stack-span-tests

#!/bin/bash
# Standalone test runner for SettingsFormBuilder, the declarative layer of the
# Settings window: bindings, populating guard, dependency dimming,
# availability, range-checked text commits, accessibility wiring. Compiled
# with the Furniture kit; no FFI.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/settings-form-builder-tests \
  Pharos/Views/NSStackView+SpanFullWidth.swift \
  Pharos/Settings/Furniture/*.swift \
  PharosTests/SettingsFormBuilderTests.swift \
  PharosTests/main.swift
/tmp/settings-form-builder-tests

#!/bin/bash
# Standalone test runner for NavigatorOrdering — how the Database Navigator
# orders schemas and the objects inside them, and when it auto-expands.
# No outline view, no database, no Xcode project involvement.
#
# `Settings.swift` comes along because the three sort enums live there, beside
# every other type `AppSettings` names; `ChartPalette.swift` because
# `ChartSettings` reads its default palette from it.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/navigator-ordering-tests \
  Pharos/Models/Settings.swift \
  Pharos/Models/Charts/ChartPalette.swift \
  Pharos/ViewControllers/SchemaBrowser/NavigatorOrdering.swift \
  PharosTests/NavigatorOrderingTests.swift \
  PharosTests/main.swift
/tmp/navigator-ordering-tests

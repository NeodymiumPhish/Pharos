#!/bin/bash
# Standalone test runner for ContentPaneLayout: the Editor / Results toggles on
# the action bar — lit while visible, the last visible area cannot be hidden.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/content-pane-layout-tests \
  Pharos/Core/ContentPaneLayout.swift \
  PharosTests/ContentPaneLayoutTests.swift \
  PharosTests/main.swift
/tmp/content-pane-layout-tests

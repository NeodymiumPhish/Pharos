#!/bin/bash
# Standalone test runner for ConnectionMenuText and PathAbbreviation: the
# place, badge and tooltip of a connection pop-up row, and the middle cut of
# a long path.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/connection-menu-text-tests \
  Pharos/Core/ConnectionMenuText.swift \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Models/Connection.swift \
  PharosTests/ConnectionMenuTextTests.swift \
  PharosTests/main.swift
/tmp/connection-menu-text-tests

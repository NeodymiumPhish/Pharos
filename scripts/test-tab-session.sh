#!/bin/bash
# Standalone test runner for the tab session's Swift side — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/pharos-tab-session-tests \
  Pharos/Models/TabSession.swift \
  Pharos/Models/QueryResult.swift \
  Pharos/Models/RowEdit.swift \
  Pharos/Core/TabSessionMonitor.swift \
  Pharos/Core/TabSessionBannerModel.swift \
  PharosTests/TabSessionTests.swift \
  PharosTests/main.swift
/tmp/pharos-tab-session-tests

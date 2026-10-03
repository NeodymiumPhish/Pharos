#!/bin/bash
# Standalone test runner for TabContextState and the transaction chip titles —
# no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/pharos-tab-context-state-tests \
  Pharos/Core/TabContextState.swift \
  Pharos/Core/TabSessionBannerModel.swift \
  Pharos/Models/TabSession.swift \
  Pharos/Models/QueryResult.swift \
  Pharos/Models/RowEdit.swift \
  Pharos/Models/Connection.swift \
  PharosTests/TabContextStateTests.swift \
  PharosTests/main.swift
/tmp/pharos-tab-context-state-tests

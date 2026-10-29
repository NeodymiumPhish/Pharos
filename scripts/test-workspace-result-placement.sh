#!/bin/bash
# Standalone test runner for WorkspaceResultPlacement — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/pharos-workspace-result-placement-tests \
  Pharos/Core/Cards/WorkspaceResultPlacement.swift \
  Pharos/Models/CardDocument.swift \
  Pharos/Models/QueryHistoryStatus.swift \
  Pharos/Models/Workspace.swift \
  PharosTests/WorkspaceResultPlacementTests.swift \
  PharosTests/main.swift
/tmp/pharos-workspace-result-placement-tests

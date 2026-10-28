#!/bin/bash
# Standalone test runner for ConnectionSidebarRows — what each row of the
# Connections Manager's sidebar says: the engine badge, the name, the
# "host:port · database" subtitle, the status dot and the unsaved dot. The
# rows themselves are drawn by ManagerSidebarVC (scripts/test-manager-sidebar.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$(mktemp -t connection-sidebar-rows-tests)"
trap 'rm -f "$BIN"' EXIT
swiftc -o "$BIN" \
  Pharos/Core/ConnectionSidebarRows.swift \
  Pharos/Windows/Manager/ManagerSidebarItem.swift \
  Pharos/Core/ConnectionMenuText.swift \
  Pharos/Core/DisplayEscape.swift \
  Pharos/Core/SshTunnelForm.swift \
  Pharos/Core/PulseClock.swift \
  Pharos/Views/ConnectionMenuArt.swift \
  Pharos/Views/TabConnectionDot.swift \
  Pharos/Models/Connection.swift \
  PharosTests/ConnectionSidebarRowsTests.swift \
  PharosTests/main.swift
"$BIN"

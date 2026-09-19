#!/bin/bash
# Standalone test runner for ConnectionConfig.sshTunnel — the per-connection
# SSH tunnel as it crosses the FFI: the key names in both directions, the
# defaults of a sparse document, and the equality the connections form's dirty
# state uses. No Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$(mktemp -t connection-ssh-tunnel-tests)"
trap 'rm -f "$BIN"' EXIT
swiftc -o "$BIN" \
  Pharos/Models/Connection.swift \
  PharosTests/ConnectionSshTunnelTests.swift \
  PharosTests/main.swift
"$BIN"

#!/bin/bash
# Standalone test runner for SshTunnelForm — the rules behind the SSH Tunnel
# section of the Connections Manager: which rows show, how the form becomes a
# model (including the masked-secret rule the Touch ID gate depends on), the
# fingerprint, and the "via <bastion>" text. No Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$(mktemp -t connections-ssh-form-tests)"
trap 'rm -f "$BIN"' EXIT
swiftc -o "$BIN" \
  Pharos/Models/Connection.swift \
  Pharos/Core/SshTunnelForm.swift \
  PharosTests/SshTunnelFormTests.swift \
  PharosTests/main.swift
"$BIN"

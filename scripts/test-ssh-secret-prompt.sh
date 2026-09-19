#!/bin/bash
# Standalone test runner for SshTunnelAuthError and SshSecretPrompt — the
# marker pharos-core puts in front of an SSH authentication failure, and the
# rule that decides whether to ask for the tunnel secret, gate first, or leave
# the failure alone. No Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$(mktemp -t ssh-secret-prompt-tests)"
trap 'rm -f "$BIN"' EXIT
swiftc -o "$BIN" \
  Pharos/Models/Connection.swift \
  Pharos/Core/SshSecretPrompt.swift \
  PharosTests/SshSecretPromptTests.swift \
  PharosTests/main.swift
"$BIN"

#!/bin/bash
# Standalone test runner for MCPStatementPolicy (what an AI app's statement
# may be before the user is asked). Foundation and the shared lexer only.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/mcp-statement-policy-tests \
  Pharos/Editor/SQLLexer.swift \
  Pharos/Editor/SQLLexSnapshot.swift \
  Pharos/Core/MCP/MCPStatementPolicy.swift \
  PharosTests/MCPStatementPolicyTests.swift \
  PharosTests/main.swift
/tmp/mcp-statement-policy-tests

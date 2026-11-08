#!/bin/bash
# Standalone test runner for MCPAccessPolicy (which tabs, Sessions,
# workspaces, history and variables an MCP client may reach) — no Xcode
# project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/pharos-mcp-access-policy-tests \
  Pharos/Models/CardDocument.swift \
  Pharos/Core/MCP/MCPAccessPolicy.swift \
  Pharos/Core/MCP/MCPJSON.swift \
  Pharos/Core/MCP/MCPToolCatalog.swift \
  Pharos/Core/MCP/MCPProtocol.swift \
  Pharos/Core/MCP/MCPAppIdentity.swift \
  PharosTests/MCPAccessPolicyTests.swift \
  PharosTests/main.swift
/tmp/pharos-mcp-access-policy-tests

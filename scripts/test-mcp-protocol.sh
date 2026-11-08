#!/bin/bash
# Standalone test runner for the MCP server's protocol layer (JSON values,
# JSON-RPC, the tool catalog, result pages) — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/pharos-mcp-protocol-tests \
  Pharos/Core/MCP/MCPJSON.swift \
  Pharos/Core/MCP/MCPToolCatalog.swift \
  Pharos/Core/MCP/MCPProtocol.swift \
  PharosTests/MCPProtocolTests.swift \
  PharosTests/main.swift
/tmp/pharos-mcp-protocol-tests

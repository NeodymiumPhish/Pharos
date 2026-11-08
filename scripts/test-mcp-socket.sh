#!/bin/bash
# Standalone test runner for the MCP transport: the app's Unix-socket server
# and the `Pharos --mcp` stdio bridge, over a real socket with a stub host.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/pharos-mcp-socket-tests \
  Pharos/Core/MCP/MCPJSON.swift \
  Pharos/Core/MCP/MCPToolCatalog.swift \
  Pharos/Core/MCP/MCPProtocol.swift \
  Pharos/Core/MCP/MCPSocket.swift \
  Pharos/Core/MCP/MCPAppIdentity.swift \
  Pharos/Core/MCP/MCPStdioBridge.swift \
  PharosTests/MCPSocketTests.swift \
  PharosTests/main.swift
/tmp/pharos-mcp-socket-tests

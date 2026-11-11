#!/bin/bash
# Standalone test runner for MCPAccessPolicy (which tabs, Sessions,
# workspaces, history and variables an MCP client may reach) and
# MCPVariableAccess (each variable's own AI apps choice) — no Xcode
# project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/pharos-mcp-access-policy-tests \
  Pharos/Models/CardDocument.swift \
  Pharos/Core/MCP/MCPAccessPolicy.swift \
  Pharos/Core/MCP/MCPVariableAccess.swift \
  Pharos/Models/QueryVariable.swift \
  Pharos/Models/Connection.swift \
  Pharos/Core/VariableSubstitutor.swift \
  Pharos/Core/VariableValueRules.swift \
  Pharos/Core/MCP/MCPJSON.swift \
  Pharos/Core/MCP/MCPToolCatalog.swift \
  Pharos/Core/MCP/MCPProtocol.swift \
  Pharos/Core/MCP/MCPAppIdentity.swift \
  PharosTests/MCPAccessPolicyTests.swift \
  PharosTests/main.swift
/tmp/pharos-mcp-access-policy-tests

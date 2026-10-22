#!/bin/bash
# Standalone test runner for FilesListRule: the Files navigator's Open,
# Recent and Older sections (60 days), its rows, and when Remove from List
# also forgets a record. Also the decode of the core's RecentFile JSON.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/files-list-rule-tests \
  Pharos/Core/FilesListRule.swift \
  Pharos/Models/RecentFile.swift \
  Pharos/Models/Connection.swift \
  PharosTests/FilesListRuleTests.swift \
  PharosTests/main.swift
/tmp/files-list-rule-tests

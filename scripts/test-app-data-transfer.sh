#!/bin/bash
# Standalone runner for AppDataTransferRules: the export form's rules and the
# words of File ▸ Export App Data… and File ▸ Import App Data…. Pure
# Foundation; CountedNounText for the counted nouns.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/app-data-transfer-tests \
  Pharos/Core/AppDataTransferRules.swift \
  Pharos/Models/AppDataTransfer.swift \
  Pharos/Core/CountedNounText.swift \
  PharosTests/AppDataTransferRulesTests.swift \
  PharosTests/main.swift
/tmp/app-data-transfer-tests

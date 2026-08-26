#!/bin/bash
# Standalone runner for the unified tag models. Foundation only — the models
# carry no behaviour beyond their Codable conformance, which is the point of
# the suite: the wire text is the contract with pharos-core.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/tag-model-tests \
  Pharos/Core/TagConditionKind.swift \
  Pharos/Models/Tag.swift \
  PharosTests/TagModelTests.swift \
  PharosTests/main.swift
/tmp/tag-model-tests

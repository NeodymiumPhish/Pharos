#!/bin/bash
# Standalone runner for TagValueNormalizer — the family table and the one
# spelling per value that the whole tag model compares by.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/tag-value-normalizer-tests \
  Pharos/Core/CIDRRange.swift \
  Pharos/Core/TagValueNormalizer.swift \
  PharosTests/TagValueNormalizerTests.swift \
  PharosTests/main.swift
/tmp/tag-value-normalizer-tests

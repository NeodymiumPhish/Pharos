#!/bin/bash
# Standalone test runner for DisplayRowPipeline. Pure Foundation, no AppKit.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/display-row-pipeline-tests \
  Pharos/Core/DisplayRowPipeline.swift \
  PharosTests/DisplayRowPipelineTests.swift \
  PharosTests/main.swift
/tmp/display-row-pipeline-tests

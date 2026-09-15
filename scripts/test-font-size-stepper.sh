#!/bin/bash
# Standalone test runner for FontSizeStepper — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/font-size-stepper-tests \
  Pharos/Editor/FontSizeStepper.swift \
  PharosTests/FontSizeStepperTests.swift \
  PharosTests/main.swift
/tmp/font-size-stepper-tests

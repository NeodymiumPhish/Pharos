#!/bin/bash
# Standalone test runner for SettingsForm — the Settings panes' layout
# furniture. Real AppKit, headless: the assertions are laid-out frames, which
# is the only place a "the form slid to the right" regression is visible.
#
# The binary name is unique to this suite: every test-*.sh writes a fixed path,
# and two suites sharing one would clobber each other when run concurrently.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/pharos-settings-form-tests \
  Pharos/Settings/SettingsForm.swift \
  PharosTests/SettingsFormTests.swift \
  PharosTests/main.swift
/tmp/pharos-settings-form-tests

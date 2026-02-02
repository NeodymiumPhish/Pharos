#!/usr/bin/env node
/**
 * Syncs version from tauri.conf.json to package.json and AboutDialog.tsx
 * Run with: node scripts/sync-version.js
 */

import { readFileSync, writeFileSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, '..');

// Read version from tauri.conf.json (source of truth)
const tauriConf = JSON.parse(readFileSync(join(root, 'src-tauri/tauri.conf.json'), 'utf-8'));
const version = tauriConf.version;

console.log(`Syncing version: ${version}`);

// Update package.json
const packageJsonPath = join(root, 'package.json');
const packageJson = JSON.parse(readFileSync(packageJsonPath, 'utf-8'));
if (packageJson.version !== version) {
  packageJson.version = version;
  writeFileSync(packageJsonPath, JSON.stringify(packageJson, null, 2) + '\n');
  console.log(`  Updated package.json`);
} else {
  console.log(`  package.json already up to date`);
}

// Update AboutDialog.tsx
const aboutDialogPath = join(root, 'src/components/dialogs/AboutDialog.tsx');
let aboutDialog = readFileSync(aboutDialogPath, 'utf-8');
const versionRegex = /Version \d+\.\d+\.\d+/;
const newVersionString = `Version ${version}`;
if (!aboutDialog.includes(newVersionString)) {
  aboutDialog = aboutDialog.replace(versionRegex, newVersionString);
  writeFileSync(aboutDialogPath, aboutDialog);
  console.log(`  Updated AboutDialog.tsx`);
} else {
  console.log(`  AboutDialog.tsx already up to date`);
}

console.log('Done!');

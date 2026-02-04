#!/usr/bin/env node
/**
 * Syncs version from tauri.conf.json to all other version references.
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

// Update package-lock.json (both root version and packages."" version)
const packageLockPath = join(root, 'package-lock.json');
try {
  const packageLock = JSON.parse(readFileSync(packageLockPath, 'utf-8'));
  let updated = false;
  if (packageLock.version !== version) {
    packageLock.version = version;
    updated = true;
  }
  if (packageLock.packages && packageLock.packages[''] && packageLock.packages[''].version !== version) {
    packageLock.packages[''].version = version;
    updated = true;
  }
  if (updated) {
    writeFileSync(packageLockPath, JSON.stringify(packageLock, null, 2) + '\n');
    console.log(`  Updated package-lock.json`);
  } else {
    console.log(`  package-lock.json already up to date`);
  }
} catch {
  console.log(`  package-lock.json not found, skipping`);
}

// Update Cargo.toml
const cargoTomlPath = join(root, 'src-tauri/Cargo.toml');
let cargoToml = readFileSync(cargoTomlPath, 'utf-8');
const cargoVersionRegex = /^version = "[^"]+"/m;
const newCargoVersion = `version = "${version}"`;
if (!cargoToml.includes(newCargoVersion)) {
  cargoToml = cargoToml.replace(cargoVersionRegex, newCargoVersion);
  writeFileSync(cargoTomlPath, cargoToml);
  console.log(`  Updated Cargo.toml`);
} else {
  console.log(`  Cargo.toml already up to date`);
}

// Update AboutDialog.tsx
const aboutDialogPath = join(root, 'src/components/dialogs/AboutDialog.tsx');
let aboutDialog = readFileSync(aboutDialogPath, 'utf-8');
const aboutVersionRegex = /Version \d+\.\d+\.\d+(-\w+)?/;
const newAboutVersion = `Version ${version}`;
if (!aboutDialog.includes(newAboutVersion)) {
  aboutDialog = aboutDialog.replace(aboutVersionRegex, newAboutVersion);
  writeFileSync(aboutDialogPath, aboutDialog);
  console.log(`  Updated AboutDialog.tsx`);
} else {
  console.log(`  AboutDialog.tsx already up to date`);
}

// Update StatusBar.tsx
const statusBarPath = join(root, 'src/components/ui/StatusBar.tsx');
let statusBar = readFileSync(statusBarPath, 'utf-8');
const statusVersionRegex = /Pharos v\d+\.\d+\.\d+(-\w+)?/;
const newStatusVersion = `Pharos v${version}`;
if (!statusBar.includes(newStatusVersion)) {
  statusBar = statusBar.replace(statusVersionRegex, newStatusVersion);
  writeFileSync(statusBarPath, statusBar);
  console.log(`  Updated StatusBar.tsx`);
} else {
  console.log(`  StatusBar.tsx already up to date`);
}

console.log('Done!');
console.log('');
console.log('Note: Cargo.lock will be updated automatically on next cargo build.');
console.log('The dist/ folder contains build artifacts that are regenerated on build.');

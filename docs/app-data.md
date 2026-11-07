---
layout: default
title: Exporting and Importing App Data
nav_order: 23
---

# Exporting and Importing App Data
{: .no_toc }

<details open markdown="block">
  <summary>Table of contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

## Overview

**File > Export App Data…** writes your own Pharos data to one file. **File > Import App Data…** reads that file back, on the same Mac or on another one. Use them to move to a new Mac, to keep a backup, or to give a colleague your connections and Sessions.

The file can hold any of these, in any combination:

| Kind | What is in the file |
|------|---------------------|
| Sessions | Every saved Session with its folder, cards, versions, connection and schema. Optionally, the results each Session keeps. |
| Query History | Every history entry, with its status, error message, schema and timing. The cached rows that history keeps for **Open Result** are not included. |
| Connections | Every connection, with its settings and SSH tunnel, **and its saved passwords**: the database password and the SSH password or key passphrase. |
| Tags | Every tag, with its color, note and rules. |
| Variables | Every query variable, with its value, type and the connections it is linked to. |

Settings, Results History workspaces, open tabs and recent files are not part of the file.

## Exporting

1. Choose **File > Export App Data…**.
2. Tick what to include. Under **Sessions**, **Include each Session's saved results** keeps the rows each Session stores. They can make the file large.
3. Choose a password (at least 8 characters) and type it twice. See [Encryption](#encryption).
4. Press **Export…**, then choose where to save the file. The name starts as `Pharos Data <date>.pharosdata`.

When **Connections** is ticked, Pharos first asks you to authenticate (Touch ID, an Apple Watch or your login password), because every saved password leaves the Keychain in this file.

When the export finishes, Pharos lists what it wrote and the size of the file. **Show in Finder** shows the file.

The file can only be opened by your macOS user account.

## Encryption

A file with **Connections** in it is always encrypted, because it holds your passwords. For any other file, **Encrypt the file with a password** is on unless you clear it.

An encrypted file is unreadable without its password. Pharos uses AES-256-GCM, with the key derived from your password by PBKDF2-HMAC-SHA256 (600,000 rounds). Pharos does not store the password anywhere and cannot recover it. Without it, the file cannot be imported.

An unencrypted file is plain JSON. Anyone who has the file can read your queries, history and tags, so keep it somewhere private.

## Importing

1. Choose **File > Import App Data…** and select the file.
2. If the file is encrypted, enter its password and press **Open**. A wrong password says **The password is not correct, or the file is damaged.**
3. Pharos shows what the file holds. Untick anything you don't want. Something the file doesn't hold is shown as **Not in this file**.
4. Choose what happens to **Items already on this Mac**:
   - **Replace them with the file's copy**: the file's copy is kept and this Mac's copy is replaced.
   - **Keep this Mac's copy**: the file's copy is skipped.
5. Press **Import**.

When the import finishes, Pharos lists what was added, replaced and kept for each kind of data. The Connections Manager, the Sessions and Results History lists, the Tag Manager and the Variable Manager update straight away.

### What counts as already on this Mac

- **Connections, Sessions and tags** are the same item when they have the same internal ID. That means items exported from this Mac, or imported here earlier. Two Sessions with the same name but different IDs are both kept.
- **Variables** are the same when they have the same ID, or the same name with the same linked connections. A variable that replaces one with the same name keeps this Mac's ID.
- **History entries** are never replaced. An entry this Mac already has stays as it is, whichever option you choose.

### What an import never does

Importing never deletes anything. Items that exist only on this Mac stay as they are.

### After importing

- A Session whose connection isn't on this Mac (and isn't in the file) opens with no connection, as it does when its connection has been deleted.
- An imported connection to a DuckDB file points to the same path it had on the other Mac. Move the file there, or edit the connection.
- Imported connections that require Touch ID still require it.
- Imported history follows your [history retention](settings.md#library--history-pane) setting. Entries older than your limit are removed the next time history is pruned.

## The file format

The file is JSON. It starts with `"format": "pharos-app-data"` and a version number. In an encrypted file, everything else is in one sealed `ciphertext` field. A file written by a newer version of Pharos says so, and asks you to update Pharos.

---
layout: default
title: Getting Started
nav_order: 2
---

# Getting Started
{: .no_toc }

<details open markdown="block">
  <summary>Table of contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

## System Requirements

- macOS 14.0 (Sonoma) or later
- A PostgreSQL server (local or remote) to connect to

## Installation

### Download from GitHub Releases

1. Go to the [Pharos Releases](https://github.com/NeodymiumPhish/Pharos/releases) page
2. Download the DMG for your Mac's architecture (Apple Silicon or Intel)
3. Open the DMG and drag Pharos to your Applications folder
4. Launch Pharos from Applications or Spotlight

### Build from Source

1. Clone the repository:
   ```
   git clone https://github.com/NeodymiumPhish/Pharos.git
   cd Pharos
   ```
2. Build the Rust core library:
   ```
   cd pharos-core
   cargo build --release
   cd ..
   ```
3. Open the Xcode project and build (Cmd+B), then run (Cmd+R)

{: .note }
Building from source requires Xcode and a Rust toolchain installed via [rustup](https://rustup.rs).

## First Launch

When you launch Pharos for the first time, you will see an empty workspace with a prompt to connect to a database. The main window contains three areas:

- **Server Rail** (left edge) -- Shows your saved connections with status indicators
- **Sidebar** -- Contains the Library (saved queries and history) and Navigator (schema browser)
- **Content Area** -- The SQL editor and results grid

## Creating Your First Connection

1. Press **Cmd+N** or choose **File > New Connection** from the menu bar
2. A connection sheet appears with the following fields:
   - **Name** -- A friendly label for this connection (e.g., "Local Dev")
   - **Host** -- The server address (defaults to `localhost`)
   - **Port** -- The PostgreSQL port (defaults to `5432`)
   - **Database** -- The database name (defaults to `postgres`)
   - **Username** -- Your PostgreSQL username
   - **Password** -- Your password (optional, stored locally)
   - **SSL Mode** -- Choose Prefer, Require, or Disable
3. Click **Test Connection** to verify your settings
4. Click **Add** to save the connection

The new connection appears in the server rail on the left. Click it to connect and start exploring your database.

## Next Steps

- Browse your database schema in the [Schema Browser](schema-browser.md)
- Write and run queries in the [Query Editor](query-editor.md)
- Learn the full set of [Keyboard Shortcuts](keyboard-shortcuts.md)

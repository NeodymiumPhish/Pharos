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

- macOS 26 (Tahoe) or later
- A PostgreSQL server (local or remote) to connect to

## Installation

### Homebrew (recommended)

```
brew tap NeodymiumPhish/pharos && brew install --cask pharos
```

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

## The Main Window

The Pharos window has three panes:

- **Sidebar** (left, toggle with **Cmd+Ctrl+S**) — one panel with three navigators, switched by the icons at its top (or from **View > Navigators**, **Cmd+Opt+1/2/3**): **Query Library** (saved queries), **Results History** (workspaces and past queries), and **Database Navigation** (the schema browser). A **Filter** field along the BOTTOM of the sidebar narrows whichever navigator is showing — **Cmd+Opt+J** puts the caret in it, and each navigator remembers its own filter text. In the Query Library a **+** pull-down sits beside the field, holding **New Query** and **New Folder**.
- **Content area** (center) — the query editor with its tabs and toolbar, above the results area (grid or chart) and its action bar.
- **Inspector** (right, toggle with **Cmd+Opt+I**) — row details, selection statistics, and schema object details. Collapsed by default.

Connections are chosen **per editor tab** from the connection pull-down in the window toolbar — there is no global connection selector.

## Creating Your First Connection

1. Press **Cmd+Shift+N** or choose **File > Manage Connections…** to open the Connections Manager window
2. Click the **+** button below the connection list
3. Fill in the connection details:
   - **Name** — a friendly label (e.g., "Local Dev")
   - **Host** — the server address
   - **Port** — the PostgreSQL port (5432 by default)
   - **Database** — the database name
   - **Username** and **Password**
   - **SSL Mode** — Prefer, Require, or Disable
4. Click **Test Connection** to verify — on success, the latency is shown and the **Default Schema** menu is populated
5. Click **Save**

Then, in the window toolbar, open the **connection pull-down** and choose your connection, then **Connect**. The Database Navigation panel populates with your schema, and you're ready to run queries.

## Running Your First Query

1. Type a query in the editor, for example `SELECT * FROM my_table LIMIT 100;`
2. Press **Cmd+Return** to run the statement under the cursor
3. Results appear in the grid below — sort, filter, [chart](charts.md), or [export](data-export.md) them from the action bar

## Next Steps

- Browse your database in the [Schema Browser](schema-browser.md)
- Learn the [Query Editor](query-editor.md)'s completion, folding, and formatting features
- Visualize results with [Charts](charts.md)
- Learn the full set of [Keyboard Shortcuts](keyboard-shortcuts.md)

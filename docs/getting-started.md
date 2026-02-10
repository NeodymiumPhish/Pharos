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

- **macOS** 10.15 (Catalina) or later
- **PostgreSQL** 10 or later (any PostgreSQL-compatible server)

## Installation

1. Download the latest `.dmg` from the [GitHub Releases](https://github.com/NeodymiumPhish/Pharos/releases) page.
2. Open the `.dmg` and drag **Pharos** into your Applications folder.
3. Launch Pharos from Applications.

{: .note }
On first launch, macOS may show a security prompt. Right-click the app and select **Open** to bypass Gatekeeper.

## Your First Connection

1. Click the **+** button at the bottom of the server rail (the narrow left sidebar).
2. Fill in your connection details:
   - **Name** — A friendly label (e.g. "Local Dev")
   - **Host** — Server address (e.g. `localhost`)
   - **Port** — PostgreSQL port (default: `5432`)
   - **Database** — Database name
   - **Username** / **Password**
   - **SSL Mode** — Disable, Prefer (default), or Require
3. Optionally assign a **color** to visually distinguish this connection.
4. Click **Test Connection** to verify. You'll see latency in milliseconds on success.
5. Click **Save** to add the connection.

Your new server appears in the server rail. Click its icon to connect.

## Interface Overview

Pharos has three main areas arranged left to right:

### Server Rail

The narrow leftmost column shows your saved connections as colored icons. Each icon displays a status indicator:

| Color | Meaning |
|:------|:--------|
| Green | Connected |
| Amber | Connecting |
| Red | Error |
| Gray | Disconnected |

Click a server icon to connect. Right-click for edit/delete options.

### Schema Navigator

The middle panel shows the database structure once connected:

- **Schema dropdown** at the top to filter by schema (or view all)
- **Search bar** to filter tables by name
- **Tree view** with expandable schemas, tables, views, foreign tables, and functions
- Right-click any table for context menu options (View Rows, Clone, Import, Export, Copy DDL)

### Query Workspace

The main area on the right contains:

- **Saved / History** sidebar toggle (collapsible)
- **Toolbar** with Run, Cancel, Clear, Save, and Format buttons
- **Query tabs** for working on multiple queries
- **Monaco editor** with syntax highlighting and autocomplete
- **Results grid** below the editor (resizable split)

## Essential Shortcuts

| Action | Shortcut |
|:-------|:---------|
| Run query | `Cmd+Enter` |
| Cancel query | `Escape` |
| New tab | `Cmd+T` |
| Close tab | `Cmd+W` |
| Save query | `Cmd+S` |
| Format SQL | `Shift+Alt+F` |
| Find in results | `Cmd+F` |
| Copy cell | `Cmd+C` |

See [Keyboard Shortcuts](keyboard-shortcuts) for the full reference.

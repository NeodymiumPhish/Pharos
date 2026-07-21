---
layout: default
title: Connections
nav_order: 3
---

# Connections
{: .no_toc }

<details open markdown="block">
  <summary>Table of contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

## Overview

Connections are managed in the **Connections Manager** window (**Cmd+N** or **File > Manage Connections…**) and selected **per editor tab** from the connection pull-down in each editor pane's toolbar. Different tabs can point at different databases at the same time.

## The Connections Manager

The Connections Manager is a two-pane window:

- **Left** — the list of saved connections. Each row shows a status dot (green = connected, yellow = connecting, red = error, gray = disconnected), the connection name, and `host:port · database`. Drag rows to reorder. Use **+** to add a connection and **−** to delete the selected one.
- **Right** — the detail form for the selected connection.

| Field | Description | Default |
|-------|-------------|---------|
| Name | A display label for this connection | — |
| Host | Server hostname or IP address | — |
| Port | PostgreSQL listening port | 5432 |
| Database | Database name to connect to | postgres |
| Username | PostgreSQL role for authentication | — |
| Password | Password for the role (stored in the Keychain) | — |
| SSL Mode | Prefer, Require, or Disable | Prefer |
| Default Schema | Schema focused on connect; populated after a successful Test Connection | None |

Edits are made inline — click **Save** to persist, or **Revert** to discard. Unsaved new connections are marked "Not saved" until saved.

## Testing a Connection

Click **Test Connection** to verify the settings:

- **Success** — shows "Connected" with the round-trip latency in milliseconds, and populates the **Default Schema** menu with the database's schemas
- **Failure** — shows the PostgreSQL error message in red

## Connecting and Disconnecting

In the editor toolbar, open the **connection pull-down**. It lists every saved connection with a live status glyph and a checkmark on the tab's active connection, followed by:

- **Connect** / **Disconnect** — open or close the connection for this tab
- **Refresh Connection** — reload schema metadata (refreshes the schema browser)
- **Manage Connections…** — open the Connections Manager

Once connected, the [Schema Browser](schema-browser.md) populates and queries in that tab run against the selected connection.

## Connection Storage

Connection metadata (name, host, port, database, username, SSL mode, default schema) is stored in a local SQLite database in Pharos's Application Support directory. Passwords are stored in the macOS Keychain, never in SQLite.

{: .note }
Passwords never leave your machine — they live in the macOS Keychain and are read into memory only to open connections.

## Multiple Connections

You can save as many connections as needed, and because the active connection is per editor tab, you can work against several databases side by side — each tab's queries, schema browser view, and results follow that tab's connection.

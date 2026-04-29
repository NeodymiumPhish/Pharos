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

Pharos manages PostgreSQL connections through a dropdown menu in the action bar above each editor pane. The dropdown shows the currently active connection and provides options to switch between saved connections, connect, disconnect, edit, or create new connections.

## Adding a Connection

Press **Cmd+N** or choose **File > New Connection** from the menu bar to open the connection sheet. Fill in the following fields:

| Field | Description | Default |
|-------|-------------|---------|
| Name | A display label for this connection | -- |
| Host | Server hostname or IP address | localhost |
| Port | PostgreSQL listening port | 5432 |
| Database | Database name to connect to | postgres |
| Username | PostgreSQL role for authentication | postgres |
| Password | Password for the role (optional) | -- |
| SSL Mode | Prefer, Require, or Disable | Prefer |
| Default Schema | Schema to focus on, or "None" for all schemas. Populated after a successful test connection. | None |

Click **Add** to save the connection. It appears immediately in the connection dropdown.

## Testing a Connection

Before saving, click the **Test Connection** button in the connection sheet. Pharos attempts to connect with the provided credentials and reports the result:

- **Success** -- Displays "Connected" with the round-trip latency in milliseconds
- **Failure** -- Displays the PostgreSQL error message in red

## Connecting and Disconnecting

Select a connection from the dropdown in the action bar and choose **Connect**. The sidebar populates with the database schema once the connection is active.

To disconnect, open the same dropdown and choose **Disconnect**.

## Editing a Connection

Open the connection dropdown in the action bar and choose **Edit**. The connection sheet opens pre-filled with the existing configuration. Make your changes and click **Save**.

## Connection Storage

Connection metadata (name, host, port, database, username, SSL mode, default schema) is stored locally in a SQLite database within the Pharos application data directory. Passwords are stored securely in the macOS Keychain, not in the SQLite database.

{: .warning }
Connection passwords are stored in the macOS Keychain on your machine. Connection metadata is stored in the local Pharos data directory.

## Multiple Connections

You can save as many connections as needed. The connection dropdown lists all saved connections, and you can switch between them by selecting from the menu. Only one connection is active per editor pane -- switching connections updates the schema browser and makes that connection the target for query execution.

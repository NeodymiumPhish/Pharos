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

Pharos manages PostgreSQL connections through a server rail on the left edge of the main window. Each connection is displayed as an icon with a status indicator showing whether it is connected, disconnected, or in an error state.

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

Click **Add** to save the connection. It appears immediately in the server rail.

## Testing a Connection

Before saving, click the **Test Connection** button in the connection sheet. Pharos attempts to connect with the provided credentials and reports the result:

- **Success** -- Displays "Connected" with the round-trip latency in milliseconds
- **Failure** -- Displays the PostgreSQL error message in red

## Connecting and Disconnecting

Click a connection icon in the server rail to connect. The status indicator changes to show the active state, and the sidebar populates with the database schema.

To disconnect, click the connected server icon again or close the connection from the server rail.

## Editing a Connection

Right-click a connection in the server rail to access the context menu, then choose **Edit**. The connection sheet opens pre-filled with the existing configuration. Make your changes and click **Save**.

## Connection Storage

Connection configurations are stored locally in a SQLite database within the Pharos application data directory. Passwords are stored in this local database.

{: .warning }
Connection passwords are stored locally on your machine. Do not share the Pharos data directory with untrusted parties.

## Multiple Connections

You can save as many connections as needed. The server rail displays all saved connections, and you can switch between them by clicking their icons. Only one connection is active at a time -- switching connections updates the schema browser and makes that connection the target for query execution.

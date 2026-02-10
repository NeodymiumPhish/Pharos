---
layout: default
title: Connection Management
nav_order: 3
---

# Connection Management
{: .no_toc }

<details open markdown="block">
  <summary>Table of contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

## Adding a Connection

Click the **+** button at the bottom of the server rail to open the New Connection dialog. Fill in the required fields:

| Field | Description | Default |
|:------|:------------|:--------|
| Name | Display name for the connection | Host:Port |
| Host | Server hostname or IP address | — |
| Port | PostgreSQL port | 5432 |
| Database | Database name | — |
| Username | PostgreSQL user | — |
| Password | User password | — |
| SSL Mode | `Disable`, `Prefer`, or `Require` | Prefer |
| Color | Visual tag for the server icon | None |

## Testing Connections

Before saving, click **Test Connection** to verify connectivity. On success, Pharos displays the round-trip latency in milliseconds. On failure, the specific error message is shown (e.g., authentication failure, host unreachable, SSL issues).

## Editing a Connection

Right-click a server icon in the server rail and select **Edit**. The Edit Connection dialog pre-fills all current values. You can modify any field including the connection color and SSL mode. Changes take effect after clicking **Save**.

## Deleting a Connection

Right-click a server icon and select **Delete**. If the connection is currently active, it will be disconnected first.

## Connection Colors

Each connection can be assigned a color from nine options: Gray, Red, Orange, Amber, Green, Blue, Purple, Pink, or None. Colors appear as the background of the server icon in the rail, making it easy to visually distinguish between environments (e.g., red for production, green for development).

## Status Indicators

Each server icon in the rail shows a small status dot:

| Status | Color | Meaning |
|:-------|:------|:--------|
| Connected | Green | Active connection to the database |
| Connecting | Amber | Connection in progress |
| Error | Red | Connection failed |
| Disconnected | Gray | No active connection |

## SSL Modes

| Mode | Behavior |
|:-----|:---------|
| Disable | No SSL encryption |
| Prefer | Use SSL if the server supports it, fall back to unencrypted |
| Require | Require SSL; fail if the server doesn't support it |

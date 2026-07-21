---
layout: default
title: Settings
nav_order: 16
---

# Settings
{: .no_toc }

<details open markdown="block">
  <summary>Table of contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

## Overview

Open Settings with **Cmd+,** or **Pharos > Settings…**. The settings sheet has three tabs: General, Editor, and Query. Click **Save** to apply, **Cancel** to discard. Settings are stored in the local SQLite database and persist across launches.

## General Tab

| Setting | Options | Default | Description |
|---------|---------|---------|-------------|
| Appearance | Auto, Light, Dark | Auto | Application color scheme; Auto follows the system. |
| NULL Display | NULL, null, (null), — (em dash), ∅ (empty set) | NULL | How NULLs render in the grid and Inspector. |
| Bool Display | TRUE/FALSE, true/false, t/f, Yes/No, 1/0, ✓/✗ | TRUE/FALSE | How booleans render throughout the app. |
| Check for updates in the background | On/Off | On | Periodically checks GitHub Releases and posts a notification when a newer version is available (see below). |
| Show leaf partitions in the Database Navigator | On/Off | Off | Shows a nested Partitions folder under [partitioned tables](schema-browser.md#partitioned-tables). |

## Editor Tab

| Setting | Options | Default | Description |
|---------|---------|---------|-------------|
| Font | System Monospace, plus installed monospace fonts (Menlo, Monaco, SF Mono, JetBrains Mono, Fira Code, Source Code Pro, Courier New) | System Monospace | SQL editor font; only installed fonts are listed. |
| Font Size | 9–24 | 13 | Editor font size in points. |
| Tab Size | 2, 4, or 8 spaces | 2 spaces | Spaces inserted per Tab press. |
| Show line numbers | On/Off | On | Line numbers in the editor gutter. |
| Wrap long lines | On/Off | Off | Soft-wrap long lines. |

## Query Tab

| Setting | Options | Default | Description |
|---------|---------|---------|-------------|
| Row Limit | 1–100,000 | 1,000 | Rows returned per query page; use [Load More](query-execution.md#row-limit-and-load-more) for additional pages. |
| Timeout | 1–3,600 seconds | 300 | Maximum time a query may run before PostgreSQL cancels it (applied as `statement_timeout` per query). |
| Confirm before DROP / DELETE / TRUNCATE | On/Off | On | Confirmation dialog before destructive [schema browser operations](table-operations.md#destructive-operations) and before running SQL containing DROP, DELETE, or TRUNCATE from the editor. |
| Notify when query completes and app is in background | On/Off | On | System notification when a query finishes while Pharos isn't frontmost. |
| Notify when query completes in a background tab | On/Off | On | Notification when a query finishes in a tab you're not viewing. |
| Notification minimum | 0–3,600 seconds | 5 | Minimum query duration before a notification fires; prevents spam from fast queries. |

## Update Checks

With background update checks enabled, Pharos checks the GitHub Releases feed shortly after launch and periodically afterwards. When a newer stable version is found you get a single notification per version — clicking it opens the release page, and a "Copy brew command" button copies the Homebrew upgrade command. Pharos never downloads or installs updates on its own.

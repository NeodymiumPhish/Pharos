---
layout: default
title: Settings
nav_order: 14
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

Open Settings with **Cmd+,** or choose **Pharos > Settings** from the menu bar. The settings sheet has three tabs: General, Editor, and Query.

## General Tab

| Setting | Options | Default | Description |
|---------|---------|---------|-------------|
| Appearance | Auto, Light, Dark | Auto | Controls the application's color scheme. Auto follows the system appearance. |
| NULL Display | NULL, null, (null), -- (em dash), empty set | NULL | How NULL values are displayed in the results grid and inspector. |
| Bool Display | TRUE/FALSE, true/false, t/f, Yes/No, 1/0, checkmark/cross | TRUE/FALSE | How boolean values are displayed throughout the app. |

## Editor Tab

| Setting | Options | Default | Description |
|---------|---------|---------|-------------|
| Font | System Monospace, plus installed monospace fonts (Menlo, Monaco, SF Mono, JetBrains Mono, Fira Code, Source Code Pro, Courier New) | System Monospace | The font used in the SQL editor. Only fonts installed on your system are shown. |
| Font Size | 9--24 | 13 | The font size in points for the SQL editor. Use the stepper or type a value. |
| Tab Size | 2 spaces, 4 spaces, 8 spaces | 2 spaces | Number of spaces inserted when pressing Tab. |
| Show line numbers | On/Off | On | Whether line numbers are displayed in the editor gutter. |
| Wrap long lines | On/Off | Off | Whether long lines wrap to the next visual line. |

## Query Tab

| Setting | Options | Default | Description |
|---------|---------|---------|-------------|
| Row Limit | 1--100,000 | 1,000 | Maximum number of rows returned by a single query page. Use [Load More](query-execution.md) to fetch additional pages. |
| Timeout | 1--3,600 seconds | 30 | Maximum time a query can run before automatic cancellation. |
| Auto-commit transactions | On/Off | On | Whether queries run in auto-commit mode. |
| Confirm before DROP / DELETE / TRUNCATE | On/Off | On | Whether a confirmation dialog appears before destructive operations. |

## Saving Settings

Click **Save** to apply your changes and close the settings sheet. Click **Cancel** to discard changes.

Settings are stored in the local SQLite database and persist across application launches.

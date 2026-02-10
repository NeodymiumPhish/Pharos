---
layout: default
title: Settings
nav_order: 13
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

Open Settings from the application menu or gear icon. Settings are organized into four tabs.

## Appearance

| Setting | Options | Default | Description |
|:--------|:--------|:--------|:------------|
| Theme | Auto, Light, Dark | Auto | Auto follows macOS system preference |
| Show Empty Schemas | On/Off | Off | Show schemas with no tables in the navigator |
| Zebra Striping | On/Off | On | Alternate row colors in the results grid |
| NULL Display | `NULL`, `null`, `(null)`, empty, `∅` | `NULL` | How NULL values appear in results |
| Results Font Size | Any number | 11 | Font size in the results grid |

### Theme Modes

- **Auto** — Follows your macOS appearance setting (Light/Dark). Changes take effect immediately when the system theme changes.
- **Light** — Light background with dark text throughout
- **Dark** — Dark background with light text, optimized for low-light environments

## Editor

| Setting | Default | Description |
|:--------|:--------|:------------|
| Font Size | 13 | Editor text size in pixels |
| Font Family | JetBrains Mono, Monaco, Menlo, monospace | Font stack for the query editor |
| Tab Size | 2 | Number of spaces per tab |
| Word Wrap | Off | Wrap long lines instead of horizontal scrolling |
| Minimap | Off | Show the code minimap on the right side of the editor |
| Line Numbers | On | Show line numbers in the gutter |

## Query

| Setting | Default | Range | Description |
|:--------|:--------|:------|:------------|
| Default Limit | 1000 | 100–10,000 | Maximum rows returned per query |
| Timeout | 30 seconds | 10s–No limit | Auto-cancel queries exceeding this duration |
| Auto-Commit | On | On/Off | Automatically commit each query |
| Confirm Destructive | On | On/Off | Prompt before DELETE, DROP, TRUNCATE, ALTER |

## Keyboard

The keyboard settings tab lets you customize all keyboard shortcuts. See [Keyboard Shortcuts](keyboard-shortcuts) for the full reference and customization instructions.

## Persistence

Settings are saved to the local SQLite database and persist across application restarts. Layout preferences (panel widths, split positions) are also saved automatically as you resize.

## Reset

Click **Reset to Defaults** to restore all settings to their original values.

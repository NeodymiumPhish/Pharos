---
layout: default
title: Saved Queries
nav_order: 13
---

# Saved Queries
{: .no_toc }

<details open markdown="block">
  <summary>Table of contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

## Overview

The **Query Library** is the first panel of the sidebar (folder icon). It holds a persistent library of SQL queries, organized into folders, so you can build and reuse a collection of frequently used queries — including their [query variables](query-variables.md).

## Saving a Query

- Press **Cmd+S** (**File > Save Query…**). If the tab is already linked to a saved query, it updates in place silently; if the tab is backed by a `.sql` file, the file is written instead; otherwise a save sheet appears asking for a **Name** and a **Folder** ("No Folder", an existing folder, or "New Folder…").
- **Save As…** in the editor toolbar's Save dropdown always opens the save sheet, creating a new saved query from the current tab.
- Saving with a name that already exists offers **Replace All / Keep Both / Cancel**.

Query variables are saved along with the SQL, so a parameterized query reopens with its variables and values intact.

## Organization

Queries can be organized into folders; folders are listed alphabetically, followed by unfiled queries. To move queries, **drag and drop** them onto a folder (multi-select works), or drag them to the root to unfile them. Empty folders are kept until deleted.

## Opening a Saved Query

Double-click a saved query to open it in a new editor tab. If it's already open in a tab, Pharos switches to that tab instead of creating a duplicate. Hovering over a query shows a tooltip preview of its SQL.

## Context Menus

**Query:**

| Action | Description |
|--------|-------------|
| Open in Tab | Opens the query in a new editor tab |
| Copy SQL | Copies the SQL to the clipboard (variables rendered) |
| Export as SQL File… | Saves the query to a `.sql` file |
| Rename… | Renames the query |
| Delete | Deletes the query |

**Folder:**

| Action | Description |
|--------|-------------|
| New Query | Creates a new query in the folder |
| Export Folder as SQL Files… | Saves every query in the folder as `.sql` files (with collision handling) |
| Rename… | Renames the folder |
| Delete | Deletes the folder and its queries (with confirmation) |

## Filtering

The sidebar's **Filter** field searches saved queries by name and SQL content.

## Storage

Saved queries live in the local SQLite database alongside connection metadata and persist across launches.

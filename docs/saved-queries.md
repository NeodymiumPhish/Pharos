---
layout: default
title: Saved Queries
nav_order: 11
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

The Saved Queries panel lives in the Library section at the top of the sidebar. It provides a persistent library of SQL queries organized by connection and folder, allowing you to build and reuse a collection of frequently used queries.

## Saving a Query

- Press **Cmd+S** to save the current tab's SQL as a saved query. If the tab is already linked to a saved query, this updates the existing query silently.
- If the tab has no linked saved query, a save sheet appears where you can provide a name, choose a folder, and select whether to associate the query with the current connection or save it as a general query.

## Organization

Saved queries are organized into two top-level sections:

- **Connection section** -- Queries associated with the active connection. The section header shows the connection name.
- **General section** -- Queries not tied to any specific connection. These are always visible regardless of which connection is active.

Within each section, queries can be organized into folders. Folders are listed alphabetically, followed by unfiled queries sorted by name.

## Opening a Saved Query

Double-click a saved query to open it in a new editor tab. If the query is already open in an existing tab, Pharos switches to that tab instead of creating a duplicate.

## Display

Each saved query in the list shows a single-line title. Hovering over a query displays a tooltip with a preview of the SQL text.

## Bottom Bar

The bottom bar of the saved queries panel has a **New Folder** button for creating new folders. Save and Save As functionality is available from the editor toolbar (not the saved queries panel itself).

## Context Menu

Right-click a saved query, folder, or section header for additional options:

### Query Context Menu

| Action | Description |
|--------|-------------|
| Open in Tab | Opens the query in a new editor tab |
| Copy SQL | Copies the query's SQL to the clipboard |
| Rename... | Opens a rename dialog |
| Delete | Deletes the query |

### Folder Context Menu

| Action | Description |
|--------|-------------|
| Rename | Renames the folder and all queries within it |
| Delete | Deletes the folder and all its queries (with confirmation) |

### Section Context Menu

| Action | Description |
|--------|-------------|
| New Query | Creates a new query in this section |
| New Folder | Creates a new folder in this section |

## Filtering

Use the search field at the top of the sidebar to filter saved queries. The filter matches against both query names and SQL content.

## Storage

Saved queries are stored in the local SQLite database alongside connection configurations. They persist across application launches.

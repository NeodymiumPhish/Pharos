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

The Saved Queries panel lets you build a library of frequently used queries organized into folders.

## Saving a Query

1. Write your SQL in the query editor
2. Press `Cmd+S` or click the save icon in the toolbar
3. Enter a name for the query
4. Optionally select a folder
5. Click **Save**

If the current tab was opened from a saved query, pressing `Cmd+S` updates the existing saved query instead of creating a new one.

## Opening a Saved Query

Click any query in the Saved panel to open it in a new tab. The tab name is set to the saved query name and is preserved through execution.

## Folder Organization

Queries can be organized into folders:

- Create a folder by typing a new folder name when saving a query
- Folders appear in the sidebar with expandable/collapsible sections
- Empty folders can be explicitly created and are preserved

### Moving Queries

Use drag-and-drop to move queries between folders:
- Drag a query onto a folder name to move it
- Drag a query to the top level to remove it from a folder

You can also right-click a query and select **Move to** for a folder selection menu.

## Searching

The search bar at the top of the Saved panel filters queries by name in real time. Matching queries are shown regardless of their folder location.

## Context Menu

Right-click any saved query for options:

| Action | Description |
|:-------|:------------|
| Open | Opens the query in a new tab |
| Move to | Move to a different folder |
| Delete | Permanently delete the saved query |

## Sidebar Toggle

The Saved Queries panel shares the left sidebar with [Query History](query-history). Toggle between them using the **Saved** and **History** tabs at the top of the sidebar.

The sidebar can be collapsed entirely by clicking the close icon, and reopened via the panel icon in the toolbar. The sidebar width is resizable by dragging its right edge.

## Storage

Saved queries are stored in the local SQLite database. Each query stores:
- Name
- SQL content
- Folder (optional)
- Associated connection ID (optional)
- Created and updated timestamps

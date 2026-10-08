---
layout: default
title: Saved Sessions
nav_order: 13
---

# Saved Sessions
{: .no_toc }

<details open markdown="block">
  <summary>Table of contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

## Overview

The **Sessions** navigator is the first navigator of the sidebar (the stack icon of the navigator selector in the window toolbar; **View > Navigators > Sessions**, **Cmd+Opt+1**). A saved Session is a whole editor tab: all of its [query cards](query-editor.md#query-cards), with their versions, **and the result of each card**. Sessions are organized into folders.

When you open a Session, its cards come back with the rows they showed when you saved it. You can also open only its queries, as a template for new work.

`{{name}}` placeholders stay in the saved SQL. They are filled from the app-wide [query variables](query-variables.md) when a query is run, copied, shared or exported.

Saved queries from earlier versions of Pharos are Sessions with no saved results. They open as they did before.

## An Empty List

Before you save anything, the panel shows **No Saved Sessions** — "Save a tab with ⌘S to keep its queries and results here." The **+** pull-down in the filter bar below it stays available, so New Session and New Folder are still one click away. A filter that matches nothing does not replace the list: the field is still live, so the empty list is the filter's own answer.

## Saving a Session

- Press **Cmd+S** (**File > Save Session…**). If the tab is already linked to a Session, the Session is updated in place. If the tab is backed by a `.sql` file, the file is written instead. Otherwise a save sheet asks for a **Name** and a **Folder** ("No Folder", an existing folder, or "New Folder…").
- **Save As…** in the editor toolbar's Save dropdown always opens the save sheet and makes a new Session from the current tab.
- A save keeps every card of the tab, including locked [earlier versions](query-editor.md#versions).
- A save keeps each card's current result: **every row the results grid holds**, including the rows that **Load More Rows** and **Load All Rows** added. It also keeps the chart and the grid/chart view of each result, the tab's connection and its schema.
- Saving with a name that already exists in the folder offers **Replace / Save as New / Cancel**. Replace replaces that Session's queries and its saved results.

### Size limit

One Session keeps up to **100 MB** of results (compressed). When a save goes over the limit, Pharos keeps the rows of the result on screen first, then the newest results. The other results are saved without their rows, and an alert tells you how many. Their queries are always saved; run them again after you open the Session.

### What is not saved

Pending cell edits, `EXPLAIN` plans, and the grid's column widths, sort and filters are not part of a Session.

### Unsaved results

A Session tab is marked as edited when its results change: a run, **Load More Rows** or **Load All Rows**. Closing it then asks whether to save, as for an edit to its SQL. Chart changes are saved with the next save, but they do not mark the tab. **Clear Results** only frees memory: the Session keeps the rows it stored, and they come back when you open it again.

## Opening a Session

Double-click a Session to **restore** it: its cards, and the result each card had when you saved it. It opens in the current tab when that tab is untouched, otherwise in a new tab beside it (see [Where opened items go](query-editor.md#where-opened-items-go)). If the Session is already open in a tab of any window, Pharos brings that tab to the front instead of making a duplicate.

The tab uses the Session's saved connection and schema when that connection still exists. Pharos does not connect for you. The saved rows show without a connection. **Load More Rows** and running a query need the connection.

To open only the queries, right-click the Session and choose **Open as Template (No Results)**. The cards open with no runs and no results, in a new tab that is not linked to the Session: **Cmd+S** asks for a name, so the original Session stays as it was.

**On double-click** in [Settings > Library & History](settings.md#library--history-pane) can change what a double-click does:

| Setting | What a double-click does |
|---------|--------------------------|
| Restore the Session | Opens the cards and their saved results (the default) |
| Open as a template (no results) | Opens the cards only, in a new unsaved tab |
| Open the Session and run it | Opens the cards without their saved results, then runs **Run All Cards**: the cards run in order, one at a time, and the run stops at the first failure |

A single click on a Session previews its SQL in the [Inspector](inspector.md) (open it with **Cmd+Opt+I**), with the number and size of its saved results and when they were saved. A Session with saved results shows the count at the trailing edge of its row, and its tooltip shows the SQL and the size.

## Context Menus

**Session:**

| Action | Description |
|--------|-------------|
| Open Session | Opens the Session with its saved results |
| Open as Template (No Results) | Opens the Session's queries only, in a new unsaved tab |
| Copy SQL | Copies the SQL to the clipboard (variables rendered) |
| Export as SQL File… | Saves the queries to a `.sql` file |
| Share… | Sends the SQL text (variables rendered) to the system share sheet |
| Rename… | Renames the Session |
| Delete | Deletes the Session and its saved results (a Session with saved results asks first) |

**Folder:**

| Action | Description |
|--------|-------------|
| New Session | Makes a new, empty Session in the folder |
| Export Folder as SQL Files… | Saves the queries of every Session in the folder as `.sql` files (with collision handling) |
| Rename… | Renames the folder |
| Delete | Deletes the folder and its Sessions, with their saved results (with confirmation) |

## Adding Sessions and Folders

The **+** pull-down at the leading edge of the sidebar's filter bar holds two items, and shows only while the Sessions navigator is on screen:

| Item | What it does |
|------|--------------|
| New Session | Makes an "Untitled Session" and opens it in a tab |
| New Folder | Makes a "New Folder" row and starts renaming it inline |

Both are also on the list's context menu.

## Organization

Folders are listed alphabetically, followed by Sessions that are in no folder. To move Sessions, **drag and drop** them onto a folder (multi-select works). Empty folders are kept until deleted. A drop that moves a Session to a different folder confirms with a short haptic tap; dropping it back where it started stays silent.

## Filtering

The sidebar's **Filter** field — along the bottom of the sidebar — searches Sessions by name and SQL. **Cmd+Opt+J** (**View > Filter in Navigator**) puts the caret in it. The text is remembered per navigator, so switching to Results History and back brings your filter with you.

## Storage

Sessions and their saved results live in the local SQLite database and persist across launches. Saved results are the Session's own copy: [history](query-history.md) retention, **Clear Query History** and the history result-cache limits never remove them. They are removed only when you delete the Session, or replaced when you save it again. A Session's results can hold data from your databases, so delete a Session when you no longer need its rows.

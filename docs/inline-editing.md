---
layout: default
title: Inline Editing
nav_order: 10
---

# Inline Editing
{: .no_toc }

<details open markdown="block">
  <summary>Table of contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

Pharos supports editing data directly in the results grid for queries that target a single table with a primary key.

## Editability Requirements

After running a query, Pharos checks whether the results are editable. For results to be editable, the query must:

1. Be a simple `SELECT` from a **single table** (no JOINs)
2. Not use `UNION`, `GROUP BY`, `DISTINCT`, subqueries, or CTEs
3. Target a table that has a **primary key**

### Status Badges

The results toolbar shows an editability badge:

| Badge | Color | Meaning |
|:------|:------|:--------|
| **Editable** | Green | You can edit cells and delete rows |
| **Read-only** | Amber | Results cannot be edited (hover for reason) |

The read-only badge includes a tooltip explaining why editing is unavailable (e.g., "No primary key", "Query contains JOIN").

## Editing Cells

1. **Double-click** a cell to enter edit mode
2. Modify the value in the inline editor
3. Press **Enter** or **Tab** to confirm the change
4. Press **Escape** to cancel the edit

Modified cells are highlighted to indicate pending changes.

## Deleting Rows

1. Select one or more rows
2. Press **Delete** or **Backspace** to mark them for deletion
3. Deleted rows are visually marked but not yet removed from the database

## Pending Changes

All edits (cell modifications and row deletions) are staged as **pending changes**. The pending changes bar appears at the bottom of the results when changes exist:

- Shows the count of pending modifications and deletions
- **Commit** — Apply all changes to the database
- **Discard** — Revert all pending changes

## Committing Changes

When you click **Commit**, Pharos:

1. Opens a database transaction
2. Executes `UPDATE` statements for modified cells, using primary key `WHERE` clauses
3. Executes `DELETE` statements for marked rows
4. Commits the transaction

If any statement fails, the entire transaction is rolled back and an error message is displayed.

{: .warning }
Committed changes are permanent. There is no undo after a successful commit.

## Merge Behavior

If you edit the same cell multiple times before committing, the changes are merged — only the final value is sent to the database. Similarly, if you edit a cell and then mark the entire row for deletion, only the deletion is applied.

## Transaction Safety

All changes use the table's primary key in `WHERE` clauses to ensure only the intended rows are affected. This prevents accidental modifications even if the underlying data has changed since the query was run.

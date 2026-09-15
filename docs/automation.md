---
layout: default
title: Shortcuts and Spotlight
nav_order: 18
---

# Shortcuts and Spotlight
{: .no_toc }

<details open markdown="block">
  <summary>Table of contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

## Overview

Pharos publishes App Intents, so its connections, saved queries and tables are
available to the Shortcuts app, to Siri and to Spotlight. Your saved queries are
also indexed, so you can find one by name from Spotlight and open it straight
into a query tab.

Nothing has to be turned on. The actions appear in Shortcuts the first time you
run Pharos, and the saved queries are indexed at launch and again whenever you
add, rename or delete one.

---

## The actions

Search for "Pharos" in the Shortcuts app's action list.

| Action | What it does |
|---|---|
| **Open Connection** | Opens a new query tab bound to a saved connection, and connects it. |
| **Run Saved Query** | Opens a saved query in a tab, runs it, and returns the rows as a CSV file. |
| **New Query Tab** | Opens a new query tab holding the SQL you supply. The query is *not* run. |
| **Open Saved Query** | Opens a saved query in a tab. The query is *not* run. |
| **Export Table** | Opens Pharos's export panel for a table, ready for you to choose the format, the columns and the destination. |

Every action brings Pharos to the front — the work happens in the app, with the
same connections, tabs and confirmations you get when you do it by hand.

### Siri phrases

Two actions have spoken phrases:

- "Open Pharos connection", "Connect to *&lt;connection&gt;* in Pharos"
- "Run a saved query in Pharos", "Run *&lt;saved query&gt;* in Pharos"

### Run Saved Query

The action opens the saved query in a tab and then runs it through the editor's
own Run command. That matters: your query variables are substituted exactly as
they are in the editor, and the destructive-SQL confirmation still appears.

{: .warning }
A saved query holding `DELETE`, `DROP`, `TRUNCATE` or `UPDATE` stops at the
confirmation sheet, and the shortcut waits for you to answer it. Nothing
destructive runs unattended.

The action returns a CSV file of the rows that were loaded, named after the
query, and reports the row count in its dialog. The CSV uses the same escaping
as **Copy as CSV** in the results grid, so the two produce identical text. It
does not page through the whole table: what you get is what the grid loaded.

The saved query's connection is used when the tab has none. A saved query with
no connection at all cannot be run, and the action says so.

### Export Table

This action gets the export panel ready; it never writes a file on its own.
Choose the format, the columns and the destination in the panel as usual.

---

## Spotlight

Press ⌘Space and type the name of a saved query. Pharos's saved queries appear
with their folder as a keyword and the first line of their SQL as the
description. Opening a result brings Pharos forward with the query in a tab.
The query is not run.

{: .note }
Spotlight indexes the saved queries of the copy of Pharos you are running. A
second, separately identified copy keeps its own index.

---

## Handing the app back to a workspace

While a query tab is bound to a workspace (that is, after its first query has
run), Pharos donates it as a user activity. The activity is searchable, so a
workspace can be reopened from outside the app; it is deliberately **not**
offered over Handoff, because a workspace names a local connection and a local
history record that mean nothing on another Mac.

---

## See also

- [Saved Queries]({{ site.baseurl }}/saved-queries) — creating and organising the queries these actions run
- [Query Variables]({{ site.baseurl }}/query-variables) — the `{% raw %}{{name}}{% endraw %}` tokens that are substituted on every run
- [Data Export]({{ site.baseurl }}/data-export) — what the export panel offers

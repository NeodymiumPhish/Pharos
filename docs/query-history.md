---
layout: default
title: History & Workspaces
nav_order: 14
---

# History & Workspaces
{: .no_toc }

<details open markdown="block">
  <summary>Table of contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

## Overview

The **Results History** panel is the third navigator of the sidebar (the clock icon of the navigator selector in the window toolbar; **View > Navigators > Results History**, **Cmd+Opt+3**). Pharos records your work as **workspaces**: one workspace per editor-tab session, capturing the editor text and every result the tab produced. Reopening a workspace restores the whole session — SQL, result tabs, even chart configurations. ([Query variables](query-variables.md) are app-wide, not part of a workspace.)

## Workspaces

Each workspace row is one line: its name on the left and when it was last active on the right. Hover the row for the rest — how many queries it holds and which connection they ran against. Workspaces are named after their connection automatically (e.g., "analytics", or "analytics +1" if a second database was also queried); rename them to anything you like.

- **Reopen** — double-click a workspace to restore it as a live editor tab with all of its result tabs rebuilt. If the workspace is already open, Pharos focuses that tab instead. Double-clicking a specific result in the preview reopens the workspace focused on that result.
- **Preview** — selecting a workspace lists its results in the lower half of the panel: each with its color dot, label, and column/row counts. A result [renamed from its result tab](results-grid.md#result-tabs) shows that name here too. Selecting a result previews its SQL in the [Inspector](inspector.md).
- **Context menu** — **Rename…**, **Duplicate**, and **Delete** (multi-select supported for deleting several at once). Individual results in the preview offer **Copy SQL** and **Delete this result**.

## Cached Results

Result data is cached with each workspace, so reopening usually shows the original rows instantly without re-executing anything. Caches are bounded (per-result and per-workspace limits); when a workspace exceeds its budget, its oldest results are demoted to "SQL only" — they reopen as re-runnable tabs marked stale instead of showing cached data.

## Earlier History

Below the workspaces, an **"Earlier history"** disclosure holds individual query entries that predate workspaces (and auxiliary queries such as chart server-aggregation runs). Each entry shows the column count and table names with the time on the right; hover it for the row count, the connection, and the start of the SQL. Double-click one to open it in a tab — cached results display immediately when available. Right-click for **Copy SQL** or **Delete**; multi-select to batch delete.

## What Gets Recorded

Every query you run is recorded automatically — the ones that worked and, by default, the ones that failed. History is retained for **90 days** — older workspaces and entries are pruned automatically.

## Failed Queries

A query that the server refused leaves a row of its own: a warning glyph, the word **Failed**, and the server's message in the row's tooltip. Cancelled runs read **Cancelled**. Screen readers hear the word, not the glyph.

- **Scope** — the control at the top of the panel chooses what the list shows: **All**, **Succeeded**, or **Failed**. **Failed** is a flat, newest-first list of every failure, whatever workspace it came from; the workspace rows step aside for it.
- **What is kept** — the SQL that ran, the connection, the time, and the message. There are no rows and no columns to keep: the query never produced any, so the row shows no counts.
- **Reopening** — double-click a failed row to put its SQL in a new tab, ready to correct and run again. Nothing is restored to the results grid, because nothing was returned.
- **Not every failure** — only answers from the server. A refusal Pharos makes on its own — no connection yet, a variable still unset, an empty editor, a tunnel that closed before anything was sent — says nothing about your SQL, and a history full of those buries the real failures, so they are not recorded.
- **Workspaces** — a failure belongs to the workspace its tab was in, and is counted among that workspace's queries. It is not a result: reopening the workspace rebuilds only the results, and the preview pane lists only those.
- **Turning it off** — **Settings ▸ Library & History ▸ Record failed queries**. Off stops new failures being recorded; rows already in the history stay until you clear them.

## Filtering

The sidebar's **Filter** field — along the bottom of the sidebar, **Cmd+Opt+J** — searches history by SQL text and workspace names. Its text is remembered per navigator.

## Nothing Recorded Yet

Before you have run anything, the panel shows **No History** — "Queries you run appear here." Under the **Failed** scope an empty list says **No Failures** instead, which is a different thing from having no history at all. A filter that happens to match nothing does not replace either message: the field is still live, so the empty list is the filter's own answer.

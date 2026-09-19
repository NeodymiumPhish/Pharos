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

Open Settings with **Cmd+,** or **Pharos > Settings…**. Settings is a window of its own, so it opens even when no query window is on screen.

A list down the left side selects the pane. The pane's name is shown in bold at the top of the right side, with **Back** and **Forward** chevrons beside it; **Cmd+[** and **Cmd+]** do the same. The window keeps one size whichever pane you are in, and remembers the size you give it. Close it with **Cmd+W**; it reopens in the pane you left.

The panes are **General**, **Appearance**, **Editor**, **Query**, **Results**, **Navigator**, **Library & History**, **Connections**, **Security & Privacy**, **Export & Import**, **Charts**, **Tags**, **Intelligence**, **Notifications**, **Shortcuts** and **Advanced**. A pane that shows **No Items** has no settings in it yet.

There is no Save button. **Every change applies at once**: a checkbox, popup, or radio applies the moment you click it, and a number field applies as you type (and again when you leave the field). Change the editor font size and the editor text changes behind the window. Settings are stored in the local SQLite database and persist across launches.

## General Pane

| Setting | Options | Default | Description |
|---------|---------|---------|-------------|
| Restore open tabs | On/Off | On | Reopen the editor tabs that were open when you last quit, in the same order and with the same tab active. A tab that had run a query comes back as its [workspace](query-history.md), with its result tabs; a tab that never ran comes back with its editor text and variables. No connection is opened automatically. Turn this off to start every launch with one empty tab. |
| Check for updates in the background | On/Off | On | Periodically checks GitHub Releases and posts a notification when a newer version is available (see below). |
| Frequency | On launch only, Daily, Weekly | Daily | How often the background check repeats. It also sets how stale a stored answer may be before the next check asks GitHub again. |
| Channel | Stable, Pre-release | Stable | Stable follows GitHub's own latest release. Pre-release takes the newest release marked pre-release that is not a draft. |
| Check Now | Button | — | Checks at once, whatever the frequency says, and puts the answer under the button. The caption otherwise shows when the last check ran. |

## Appearance Pane

| Setting | Options | Default | Description |
|---------|---------|---------|-------------|
| Appearance | Auto, Light, Dark | Auto | Application color scheme; Auto follows the system. |
| NULL display | NULL, null, (null), — (em dash), ∅ (empty set) | NULL | How NULLs render in the grid and Inspector. |
| Boolean display | TRUE/FALSE, true/false, t/f, Yes/No, 1/0, ✓/✗ | TRUE/FALSE | How booleans render throughout the app. |
| NULL style | Italic, Dimmed, Plain | Italic | How a NULL is set apart from a real value in the grid. **Differentiate Without Color** (System Settings ▸ Accessibility ▸ Display) keeps the italic face whatever this says, because a colour-only difference is no difference with that option on. |
| Show result tabs in a vertical panel | On/Off | On | Lists [result tabs](results-grid.md#result-tabs) down a panel at the right edge of the editor, instead of along a bar above the results grid. The two never show together. |
| Always show scroll bars | On/Off | Off | Off follows the system's **Show scroll bars** preference (System Settings ▸ Appearance), so the editor and the results grid show scroll bars only while scrolling, or always, as the rest of your Mac does. On pins classic scroll bars on both, so a wide result always shows how much of it is off screen. |

## Navigator Pane

The [Database Navigator](schema-browser.md): what it shows, in what order, and
what a double-click on a row does. Every default is what the Navigator did
before the setting existed, so nothing changes until you touch a control.

### Schemas

| Setting | Options | Default | Description |
|---------|---------|---------|-------------|
| Order schemas by | Name, Default schema first | Name | Name is the order the server returns, which is what the Navigator has always shown. Default schema first lifts the schema the connection names to the top and leaves the rest by name; a connection that names none is unchanged. |

### Objects

| Setting | Options | Default | Description |
|---------|---------|---------|-------------|
| Order objects by | Kind, then name; Name; Size; Row estimate | Kind, then name | Kind, then name lists the tables by name, then the views by name. Name mixes views in among the tables. Size and Row estimate put the largest first; an object that has not been measured yet goes to the END, by name, never to the front — an unmeasured table is not a small one, and sorting it as zero would reshuffle the list as the measurements arrived. |
| Show leaf partitions | On/Off | Off | Shows a nested Partitions folder under [partitioned tables](schema-browser.md#partitioned-tables). |
| Order partitions by | Partition bound, Name, Size | Name | The order inside that Partitions folder. Partition bound reads each partition's own FROM or IN value, so a range-partitioned table reads in date order; MINVALUE comes first, MAXVALUE after the real keys, and DEFAULT last. |
| Open the default schema | On/Off | On | Expands the schema the connection names — or `public`, when it names none — as soon as the tree is built. |
| Only below | 0–100,000 objects | 500 | The ceiling for the row above. Opening one row with more children than this blocks the app for seconds, so a schema above the ceiling waits for you to click its disclosure triangle. |

### Actions

| Setting | Options | Default | Description |
|---------|---------|---------|-------------|
| On double-click | Expand or collapse, View contents, Describe, Insert the name in the editor | Expand or collapse | Every action but Expand runs exactly what the row's own context menu runs. A row the action means nothing for — a schema, a column — still expands. Describe opens the table's DDL sheet, and only a plain table has one. |
| Limit the rows View contents fetches | On/Off | On | Uses Query ▸ **Default row limit**. Off selects every row, as the context menu's **View All Contents** does. Read only while the double-click action is View contents. |
| Row counts in the Limit menu | 10 / 100 / 1,000 / 10,000 · 10 / 50 / 100 / 500 · 100 / 1,000 / 10,000 / 100,000 · 1,000 only | 10 / 100 / 1,000 / 10,000 | The rows the Navigator's **View Contents (Limit…)** submenu offers on a table, a view or a partition. A whole set at a time, not a list you edit. |

## Library & History Pane

The [Query Library](saved-queries.md) navigator and the Save Query sheet, then
the [Results History](query-history.md) navigator.

### Query Library

| Setting | Options | Default | Description |
|---------|---------|---------|-------------|
| Default folder | Any folder name, or empty | *(empty)* | The folder the Save Query sheet opens on. Empty opens on **No Folder**, which is what the sheet has always done. A name no folder carries yet is ignored — the sheet lists the folders your saved queries are in, and **New Folder…** still makes one. |
| Order queries by | Folder, then name; Name; Recently updated | Folder, then name | Folder, then name is the grouped tree with a row per folder, then the unfiled queries. Name and Recently updated are one flat list, with no folder rows — the folder a query is in is unchanged, only hidden. Recently updated puts the newest first and breaks a tie by name. |
| On double-click | Open in a tab, Open in a tab and run it | Open in a tab | Open in a tab and run it runs the query as soon as its tab is there. A tab with no connection opens the query and stops. The context menu's **Open in Tab** always just opens, whichever this says. |

### History

| Setting | Options | Default | Description |
|---------|---------|---------|-------------|
| Entries to load | 10–5,000 entries | 200 | How many of the newest entries the Results History navigator fetches. The list is one fetch, not pages, so this is all of the history you can see at once. Nothing is deleted: a lower number only shows fewer. |

**Clear Query History…** deletes every entry and the cached results of each, and removes any workspace left with no entries. The confirmation names the exact number first, read from the store with the same rule the deletion uses, so it can never take more than it said. It cannot be undone, and Cancel is the default button.


## Editor Pane

Everything about the SQL editor itself. Every default is what the editor did
before the setting existed, so nothing changes until you touch a control.

### Font

| Setting | Options | Default | Description |
|---------|---------|---------|-------------|
| Font | System Monospace, plus installed monospace fonts (Menlo, Monaco, SF Mono, JetBrains Mono, Fira Code, Source Code Pro, Courier New) | System Monospace | SQL editor font; only installed fonts are listed. |
| Size | 8–36 | 13 | Editor font size in points. Pinch to zoom, or ⌘+ / ⌘−, writes this too. |

### Text

| Setting | Options | Default | Description |
|---------|---------|---------|-------------|
| Tab size | 2, 3, 4, or 8 spaces | 2 spaces | One indent level. |
| Insert spaces for Tab | On/Off | On | Off writes one tab character instead. Shift-Tab takes back one level either way. |
| Indent new lines automatically | On/Off | On | Return copies the leading whitespace of the line you are leaving. |
| Close brackets automatically | On/Off | On | Typing `(` or `[` also writes the closer, and Backspace over an empty pair takes both away. Typing straight before existing text never pairs. Typing an opener with text selected wraps the selection. |
| Close quotes automatically | On/Off | On | The same for `'`. An apostrophe typed after a letter is left alone. |
| Wrap long lines | On/Off | Off | Soft-wrap long lines. |
| Show line numbers | On/Off | On | Line numbers in the editor gutter. |
| Highlight the current line | On/Off | On | A faint wash behind the line holding the caret. The band follows the line as laid out, so a collapsed fold above it never moves it off. |
| Show run buttons in the gutter | On/Off | On | The band beside each statement, and the play glyph it shows on hover. Off leaves the band unclickable as well as undrawn; **⌘↩** still runs the statement at the cursor. |
| Allow code folding | On/Off | On | The chevrons that collapse a CTE, a subquery, a `CASE` or a `BEGIN` block. Turning this off opens everything that is folded, so no text stays hidden behind a switch you have just turned off. |
| Minimum lines to fold | 2–50 | 3 | A shorter region gets no chevron. Used only while code folding is on. |

### Completion

| Setting | Options | Default | Description |
|---------|---------|---------|-------------|
| Open the list | Never, After a dot, After a dot and while typing | After a dot | When the completion list opens on its own. **Control-Space** always opens it, whichever this says. The list never opens inside a string literal or a comment. The typing trigger waits 120 ms after the last keystroke. |
| Characters before suggesting | 1–5 | 1 | How much of an identifier must be typed before the typing trigger fires. Used only while the list opens **After a dot and while typing**; a dot opens it whatever this says. |
| Maximum suggestions | 5–200 | 200 | The most rows the list ever holds. A large schema can match thousands, and building them all is work nobody sees. |
| Keyword case | UPPERCASE, lowercase, Match what I type | UPPERCASE | The case a keyword takes as it is inserted. **Match what I type** follows the word you have started: all capitals gives capitals, lowercase gives lowercase, and mixed leaves the keyword as the list spells it. Schema, table and column names always keep the case the database gave them. |

### Paste

| Setting | Options | Default | Description |
|---------|---------|---------|-------------|
| Offer to format a pasted list | On/Off | On | A paste that looks like bare values offers a **Format as SQL list** button. Press Tab to take it, Esc to leave it. The paste itself is never changed on its own, and **Format as SQL list** stays in the editor's context menu whatever this says. |
| Quote values with | Single quotes, Double quotes, No quotes | Single quotes | How that formatter wraps a value. A list that is all numbers, all booleans or all `NULL` is left bare whichever this says, because quoting it would change what it means. |

### Colours

| Setting | Options | Default | Description |
|---------|---------|---------|-------------|
| Syntax colours | System, Vivid, Dusk | System | The colours the editor gives keywords, functions, strings, numbers, comments, types and `{{variable}}` tokens. System follows the macOS palette and is the editor you have always seen. Every theme reads in both light and dark appearance. |

## Query Pane

| Setting | Options | Default | Description |
|---------|---------|---------|-------------|
| ⌘↩ runs | The statement at the cursor, The selection else the statement, The whole editor | The statement at the cursor | What **Cmd+Return** sends. The statement at the cursor is what Pharos has always run. With the second, a selection wins and a whitespace-only selection falls back to the statement. **Run All Queries** always runs every statement, whatever this says. |
| Row limit | 1–100,000 | 1,000 | Rows returned per query page; use [Load More](query-execution.md#row-limit-and-load-more) for additional pages. |
| Statement timeout | 1–3,600 seconds | 300 | Maximum time a query may run before PostgreSQL cancels it (applied as `statement_timeout` per query). |
| Confirm queries that change the database | On/Off | On | Confirmation dialog before destructive [schema browser operations](table-operations.md#destructive-operations) and before running SQL containing DROP, DELETE, TRUNCATE, UPDATE, ALTER, INSERT or GRANT from the editor. |
| DROP, ALTER, TRUNCATE, DELETE, UPDATE, INSERT, GRANT and REVOKE | On/Off each | On | Which kinds still ask, while the switch above is on. A keyword Pharos learns later always asks until it is given a switch of its own, so a new kind can never run unannounced. These do not affect **Explain Analyze**, which refuses a destructive statement outright rather than confirming it. |
| When a query fails | Open the error sheet, Show a banner, Post a notification, Say nothing | Open the error sheet | How loudly a failure interrupts. The failure is recorded on its tab whatever this says, and the tab's error badge always opens the full list. |
| Open the error sheet on | The first failure, The second failure, Never | The second failure | The second failure is what Pharos has always done: the first one gets an inline banner instead, so the editor stays usable. |
| Show details when you cancel a query | On/Off | On | Opens the error sheet for a query you cancelled. The failure is recorded on its tab either way. |

## Results Pane

Everything about the [results grid](results-grid.md). NULL display, boolean display and NULL style are in the Appearance pane instead: those are value rendering, and they reach the Inspector too.

### Grid

| Setting | Options | Default | Description |
|---------|---------|---------|-------------|
| Density | Compact, Normal, Comfortable | Normal | Row height, and a point off or on the text size. |
| Text size | 9–18 pt | 12 | Body cell font size. Density is added to it, and the result is held inside 9–18. |
| Use a monospaced font | On/Off | On | Digits share one advance, so a numeric column lines up on its last digit. Off uses the system font at the same size. |
| Alternating row colours | On/Off | On | The striped row background. |
| Grid lines | None, Horizontal, Both | Both | The rules drawn between cells. |
| Show row numbers | On/Off | On | The leading `#` column. Hiding it leaves the tag gutter beside it where it is. |
| Show column type icons | On/Off | Off | A glyph for the data type beside its name in the column header. Off is the header as it has always been: the type as text only. |

### Columns

| Setting | Options | Default | Description |
|---------|---------|---------|-------------|
| Column width | Fit to content, Fixed width | Fit to content | Fit to content measures the header and a sample of the rows. Double-clicking a column's right edge always re-fits that column, whichever this says. |
| Fixed width | 40–1,000 pt | 200 | The width every column starts at in Fixed width mode. Dimmed in Fit to content mode. |
| Maximum column width | 100–4,000 pt | 1,000 | No column is ever made wider than this, by fitting or by dragging. |

### Cells

| Setting | Options | Default | Description |
|---------|---------|---------|-------------|
| Maximum characters per cell | 0–10,000 | 0 | Longer values are drawn cut short with an ellipsis; 0 draws all of them. Counted in characters, so an accented letter or an emoji is one. Display only — copy, export, find, filter and sort always use the whole value. |
| Escape control characters | On/Off | On | Shows invisible and direction-changing characters as `<U+XXXX>`. Turning it off lets a value **display as something it is not**: a right-to-left override can make a filename ending `gpj.exe` read as one ending `.jpg`. Leave it on unless you are reading text you trust. Display only, whichever this says. |

### Find

| Setting | Options | Default | Description |
|---------|---------|---------|-------------|
| Match | Contains, Whole word, Regular expression | Contains | How the [find field](results-grid.md#find-in-results) matches a cell. Whole word does not match inside a longer word. A regular expression that cannot be read turns the field red and matches nothing, rather than matching everything. |
| Match case | On/Off | Off | Applies to all three match modes. |

### Copy

| Setting | Options | Default | Description |
|---------|---------|---------|-------------|
| Copy with ⌘C | TSV, CSV, Markdown, SQL INSERT, SQL WITH | TSV | The Copy menu still offers every format. A copy also carries the TSV form, so a paste into a spreadsheet lands as a table whichever this says. |
| Include column headers | On/Off | On | The same switch as "Include Headers" in the grid's own Copy menu; changing it in either place changes it in both. |
| Also copy as rich text | On/Off | On | Writes an HTML table beside the text, so a paste into Mail or Notes arrives as a table. Off leaves plain text only — and a drag out of the grid offers the same flavours. |

### Editing

| Setting | Options | Default | Description |
|---------|---------|---------|-------------|
| Allow editing cells in the grid | On/Off | On | Off makes every result read-only. An [edit](results-grid.md#editing-cells) is never written until you review and apply it, whichever this says. |

### Result tabs

| Setting | Options | Default | Description |
|---------|---------|---------|-------------|
| Maximum result tabs | 0–50 | 0 | Per editor tab. Reaching the limit closes the oldest result you have not looked at and have not renamed, and says so; a result you have viewed or named is never taken away. 0 keeps them all. |
| Open new tabs with the result-tabs panel | On/Off | On | The value a *new* editor tab starts from. Toggling the panel in a tab also sets this. Only used while Appearance ▸ **Show result tabs in a vertical panel** is on. |

## Notifications Pane

| Setting | Options | Default | Description |
|---------|---------|---------|-------------|
| Notify when the app is in the background | On/Off | On | System notification when a query finishes while Pharos isn't frontmost. |
| Notify for a background tab | On/Off | On | Notification when a query finishes in a tab you're not viewing. |
| Minimum duration | 0–3,600 seconds | 5 | Minimum query duration before a notification fires; prevents spam from fast queries. |
| Play a sound | On/Off | On | Whether a posted notification carries the system's default notification sound. Off posts the same notification silently. Notification Centre can silence Pharos entirely, whatever this says. |
| Badge the Dock icon | On/Off | On | Counts the queries that finished while you were in another app and shows the count on the Dock tile, whatever the three gates above say — a fast query that never reaches the duration threshold is still counted. The count clears the moment you come back to Pharos. Off counts nothing. |

### In the window

| Setting | Options | Default | Description |
|---------|---------|---------|-------------|
| Message duration | Short (1 second), Normal (2 seconds), Long (5 seconds) | Normal | How long a message at the foot of the window stays before it fades. Normal is the 2 seconds these messages have always used. A few messages ask for longer on their own — a rejected edit, a sanitised label — and keep the time they ask for whatever this says. |

## Intelligence Pane

The on-device model, and the seven features that use it. The master switch is
first; each feature below it is indented and takes effect only while the
master is on. Every default is On — all seven ran whenever Apple Intelligence
was allowed before the switches existed — so nothing changes until you clear
one. Nothing here sends anything anywhere.

| Setting | Options | Default | Description |
|---------|---------|---------|-------------|
| Use Apple Intelligence features | On/Off | On | Explain errors, suggest names and charts, draft SQL and summarise plans with the on-device model. Nothing leaves this Mac. The row is dimmed, with the reason in its place, on a Mac that cannot run the model. |
| Describe the query | On/Off | On | The editor toolbar's **Describe the query…** button, which drafts SQL from a sentence. Off takes the button away. |
| Allow drafts that write | On/Off | On | Off drafts reads only: a draft that is not a plain `SELECT` — or that contains `DELETE`, `DROP`, `UPDATE` and the rest — is refused with a sentence saying so, instead of being offered behind its confirmation. Pharos never runs a draft either way. |
| Explain query errors | On/Off | On | The explanation block on the [query-error sheet](query-errors.md). Off leaves the error's own text, which is unchanged. |
| Summarise query plans | On/Off | On | The generated sentence above an `EXPLAIN` result. The plan tree itself is not generated and is always shown. |
| Suggest charts | On/Off | On | Whether **Suggest chart** asks the model. Off, the button stays and applies the chart Pharos recommends for these columns from the column shapes alone. |
| Suggest names | On/Off | On | Fills the name field in the **Save Query** sheet and in the two rename dialogs with a suggestion. The field opens with the name it always had and the suggestion only replaces it if it arrives before you type. |
| Name tabs automatically | On/Off | On | Renames an editor tab still called "Query 1" from its SQL the first time it runs. A tab you have named yourself is never touched. |

### Feedback

The thumbs under a generated answer are recorded on this Mac, with a digest of
the prompt rather than the prompt itself. The Intelligence pane reports how
many of each you have given. There is no button to clear them yet.

## Shortcuts Pane

A read-only list of every key Pharos answers: the command, the menu it lives in, and the shortcut. The search field filters on all three, so `⌘T`, `tab` and `File` each narrow the list. The menu entries are read from the live menu bar when the pane opens, so a command added to a menu appears here with nothing else to update; the keys that belong to a view and never appear in a menu — Escape in the completion list, Return in the results grid — are listed beside them.

Nothing here can be rebound, and that is on purpose: macOS already does it. **System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ App Shortcuts** takes a menu command's exact title for Pharos and gives it whatever key you like, and a second rebinding mechanism inside the app would fight it.

## Charts Pane

The default series palette used by every chart: one color well per slot, **Add color** and the minus button to change how many slots there are, and **Reset to defaults** for the built-in set. See [Charts](charts.md#colors) for how a chart chooses between this palette and its own override.

## Security & Privacy Pane

Nothing leaves this Mac. Pharos has no account, no telemetry and no analytics;
everything below is written to your own disk and read by your own Mac. Both
switches take effect at once — neither needs a relaunch.

| Setting | Options | Default | Description |
|---------|---------|---------|-------------|
| Find saved queries in Spotlight | On/Off | On | Puts each saved query's name, folder and SQL in the system index, so Spotlight finds it and opens it in Pharos. Turning this off does not merely stop indexing: it removes everything Pharos has already put in Spotlight. |
| Collect performance reports | On/Off | On | Subscribes to the system's daily MetricKit payloads and writes them to `~/Library/Logs/Pharos` as `metrickit-*.json`, for you to read or attach to a bug report. Nothing is uploaded. Off unsubscribes at once. |

Passwords are held in the macOS Keychain and are not settings; see
[Connections](connections.md).

## Advanced Pane

| Setting | Options | Default | Description |
|---------|---------|---------|-------------|
| Refetch metadata after | 0–1,440 minutes | 0 | How old a connection's cached schema may be before Pharos fetches it again when you next switch to that connection. 0 means never expire, which is what the cache has always done: an entry lives until the connection closes or you refresh it by hand. |

| Button | What it does |
|--------|--------------|
| Clear Metadata Cache | Drops every connection's cached schemas, tables and columns. The next use of a connection fetches them again. Completion has nothing to offer until it does. |
| Reveal Logs in Finder | Opens `~/Library/Logs/Pharos` in the Finder — the crash logs, and the performance reports if they are being collected. |
| Reset All Settings… | Asks once, then puts every preference in this window back to its default and forgets where the windows, panels and split views were left. Your connections, saved queries, history, variables and tags are not touched. |

## Update Checks

With background update checks enabled, Pharos checks the GitHub Releases feed shortly after launch and then at the **Frequency** you chose. When a newer stable version is found you get a single notification per version — clicking it opens the release page, and a "Copy brew command" button copies the Homebrew upgrade command. Pharos never downloads or installs updates on its own.

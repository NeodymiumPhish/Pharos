---
layout: default
title: Query Format for AI Agents
nav_order: 22
---

# Pharos Query Format for AI Agents

Give this file to an AI agent that drafts SQL for Pharos. It tells the agent how to write a query name and query notes so that Pharos reads them correctly.

The rules come from the Pharos `.sql` text form. The parser is `pharos-core/src/commands/cards.rs` (`split_cards`). The user documentation is [Opening and Saving SQL Files](query-editor.md#opening-and-saving-sql-files).

---

## 1. Instructions for the agent

When you draft one or more queries for Pharos, write them as one `.sql` script in the format below.

1. Write one block for each query.
2. Start each block with a name line: `-- name: <Query Name>`.
3. Put the notes block on the line directly after the name line.
4. Put the SQL statement directly after the notes block.
5. End each statement with `;`.
6. Put one blank line between blocks.

### The block

```sql
-- name: <Query Name>
/*
=====================================================================
<First line of the notes>
<More lines of notes>
=====================================================================
*/
<SQL statement>;
```

### Complete example

```sql
-- name: Active Users This Month
/*
=====================================================================
Q1. ACTIVE USERS THIS MONTH
Users who signed in at least once since the first day of this month.
One row for each user. Sort: last sign-in, newest first.
=====================================================================
*/
SELECT u.id, u.email, max(s.signed_in_at) AS last_sign_in
FROM users u
JOIN sessions s ON s.user_id = u.id
WHERE s.signed_in_at >= date_trunc('month', now())
GROUP BY u.id, u.email
ORDER BY last_sign_in DESC;

-- name: New Signups by Day
/*
=====================================================================
Q2. NEW SIGNUPS BY DAY
Daily count of new accounts for the last {{days}} days.
Compare the peaks with the campaign dates in Q1 notes.
=====================================================================
*/
SELECT created_at::date AS day, count(*) AS signups
FROM users
WHERE created_at >= now() - make_interval(days => {{days}})
GROUP BY 1
ORDER BY 1;
```

---

## 2. Query name rules

| Rule | Detail |
|---|---|
| Line form | `-- name: ` then the name. The keyword `name:` is not case-sensitive, and spaces around it are ignored. |
| Position | The name line must be the last header line before the query's notes block or statement. |
| One line | A name has one line only. Pharos joins all whitespace in a name to single spaces when it writes the file. |
| Length | Keep the name at 40 characters or fewer. A longer name shows as an ellipsis in the tab label. |
| Words | Use two to four words. Say what the query returns, not how it gets the data. |
| Case | Use Title Case. Keep identifiers as they are written (`pg_class`, `orders.id`, `v2`). |
| Punctuation | Do not end the name with `.`, `,`, `;`, `:` or `!`. Do not put quotes around the name. |
| Characters | Do not use control characters, zero-width characters, or bidirectional marks. Pharos removes them from names typed in the app. |
| Unique names | Give each query a different name. Two blocks with the same name and no `-- version:` line are two different queries. |
| No name | A query without a name line is permitted. Pharos shows it as an unnamed card. |

The name style (two to four words, Title Case, 40 characters, no end punctuation) is the same style that the Pharos on-device name suggestion uses (`Pharos/Intelligence/NameSuggestionPolicy.swift`). Pharos does not reject a name that breaks the style. The style keeps the names consistent with names that Pharos makes.

---

## 3. Query notes rules

Pharos reads a notes block only when all of these conditions are true:

1. The block is one `/* … */` comment.
2. The first non-blank line inside the comment is a border: three or more `=` characters and nothing else.
3. The last non-blank line inside the comment is also a border.
4. The block is the first thing after the name line. Only blank lines can come between them. A query without a name line can also have a notes block, directly before its statement.
5. A SQL statement (or `;`) follows the block.

If one condition is false, the comment stays in the SQL text of the card and does not become notes.

| Rule | Detail |
|---|---|
| Border | Use 69 `=` characters. This is the border that Pharos writes (`NOTES_BORDER`). Pharos accepts any border of three or more `=`. |
| Text | Notes are plain text. Pharos does not render Markdown. |
| Blank lines | Blank lines inside the notes are kept. Blank lines directly inside the borders are removed. |
| Comment marks | Do not write `/*` or `*/` inside the notes. PostgreSQL nests block comments, so an extra `/*` or `*/` changes where the comment ends. If you must show them, write `/ *` and `* /`. This is what Pharos writes. |
| Borders inside | Do not put a line of only `=` characters inside the notes. The parser can read it as a border. |
| Variables | You can write `{{name}}` tokens in notes. Pharos does not replace tokens in notes. |
| Scope | Notes belong to the query, not to one version. Write the notes block one time for each query. |

### Recommended notes layout

This layout is a recommendation. Pharos does not require it. It is the layout of the examples in the Pharos tests and user documentation.

```text
Q<n>. <QUERY TITLE IN CAPITALS>
<What the query returns, in one or two sentences.>
<What to compare it with, or how to read the result.>
```

- Use `Q<n>.` to number the queries in the order of the script. Other notes can refer to a query by its number.
- Keep each line short. The notes area is beside the SQL editor, so long lines wrap.

---

## 4. Statement rules

- End each statement with `;`. The statement after a block belongs to that block's name and notes.
- Put only one statement in each block. Pharos makes one card for each statement. A second statement without a name line becomes an unnamed card.
- Ordinary comments are permitted after the notes block and inside the statement. They stay in the card's SQL.
- Use `{{name}}` for query variables. A variable name has the characters `A-Z`, `a-z`, `0-9` and `_`. It must have at least one letter or `_`. Pharos replaces tokens in SQL before it runs the query, and it does not run a query that has a token without a value.

---

## 5. Errors to prevent

| Error | Result in Pharos | Correct form |
|---|---|---|
| Notes block above the name line | The comment becomes a separate unnamed card. The query has no notes. | Name line first, then the notes block. |
| A `--` comment between the name line and the notes block | The notes block stays in the SQL. The query has no notes. | Put the `--` comment after the notes block, or in the notes. |
| No border lines, or one border only | The comment stays in the SQL. | A border on the first and last lines inside `/* */`. |
| `/*` or `*/` inside the notes | The comment ends at the wrong place, and the SQL can break. | Write `/ *` and `* /`. |
| Name on two lines | Only the first line is the name. The second line goes into the SQL. | One line. |
| `-- version:` line | Pharos reads versions of one query. | Do not write `-- version:` lines. Pharos adds them when it saves locked versions. |
| No `;` at the end of a statement | The next block joins this statement as one card. The next query's name is lost. | End each statement with `;`. |

---

## 6. How to put the script into Pharos

Pharos reads names and notes only when it splits text into cards. Use one of these methods:

1. Save the script as a `.sql` file. Open it with **File > Open…** (⌘O), or drop it on the editor.
2. Select the script text in another app. Choose **Services > Run in Pharos**. Pharos opens the text in a tab. It does not run the query.
3. Use the Shortcuts action **New Query Tab** with the script as the **SQL** value.

Paste into a card editor puts all of the text into one card. Paste does not split the text into cards, and it does not read names or notes.

When Pharos opens a file, a card that has ordinary comments above its statement shows **Import Comments to Note** on its Notes button. This moves those comments into the notes. Use the notes block format to make this step unnecessary.

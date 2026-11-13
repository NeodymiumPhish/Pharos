#!/bin/bash
# Grades "Describe a query" with a REAL model against a fixture database. Not
# part of the unit sweep: it needs a model, a local Postgres.app, and minutes
# rather than seconds.
#
#   scripts/eval-sql-draft.sh baseline [out.json]   # the tool-calling drafter on main, on-device model
#   scripts/eval-sql-draft.sh pipeline [out.json]   # the working tree's pipeline, on-device model
#   scripts/eval-sql-draft.sh endpoint [out.json]   # the working tree's pipeline, a custom AI endpoint
#
# baseline and pipeline need Apple Intelligence. endpoint asks an
# OpenAI-compatible endpoint instead, through the app's own client, so a model
# can be scored against the on-device one on the same 22 requests:
#
#   EVAL_ENDPOINT=http://localhost:11434/v1 EVAL_ENDPOINT_MODEL=llama3.1 \
#     scripts/eval-sql-draft.sh endpoint
#
#   EVAL_ENDPOINT          the API root. https://, or http:// for this Mac only,
#                          as in Settings ▸ Intelligence.
#   EVAL_ENDPOINT_MODEL    the model's name as the endpoint lists it.
#   EVAL_ENDPOINT_CONTEXT  the model's window in tokens (default 8192). The
#                          pipeline fits its tables into this, so it changes
#                          the score: say which size a result was run at.
#   EVAL_ENDPOINT_KEY      the API key, if the endpoint needs one. Read from
#                          the environment and never printed.
#   EVAL_ENDPOINT_LOG      a file to write every request and answer to, as
#                          sent and received, for when an answer is not read.
#
# An endpoint on another machine is sent the fixture's table names and the 22
# requests, nothing of yours.
#
# The pipeline reads the fixture tables' DDL, as the app does. Three more
# switches, for scoring one design against another:
#
#   EVAL_DDL=0        no DDL: the pipeline drafts from the compact block alone.
#   EVAL_READ=whenLarge|always
#                     when step 3 asks the model about the tables it has read
#                     (default: the app's own policy, whenLarge).
#   EVAL_CONTEXT=4096 budget every request as if the model's window were this
#                     size. The model's real window is unchanged, so this can
#                     only be set smaller than it.
#
# EVAL_CASES=scripts/draft-eval/cases-adjust.json scores changes to a
# statement a card already holds (pipeline and endpoint modes only).
# EVAL_ONLY=id1,id2 runs a subset; EVAL_TIMEOUT sets seconds per case.
# The fixture is (re)loaded into database pharos_draft_eval on every run.
set -euo pipefail
cd "$(dirname "$0")/.."

mode="${1:?usage: eval-sql-draft.sh baseline|pipeline|endpoint [out.json]}"
case "$mode" in
  baseline|pipeline)
    # The on-device modes must not pick an endpoint up from the environment.
    unset EVAL_ENDPOINT EVAL_ENDPOINT_MODEL EVAL_ENDPOINT_CONTEXT EVAL_ENDPOINT_KEY
    ;;
  endpoint)
    [ -n "${EVAL_ENDPOINT:-}" ] \
      || { echo "set EVAL_ENDPOINT to the API root of the endpoint, such as http://localhost:11434/v1" >&2; exit 2; }
    [ -n "${EVAL_ENDPOINT_MODEL:-}" ] \
      || { echo "set EVAL_ENDPOINT_MODEL to the name of the model" >&2; exit 2; }
    ;;
  *) echo "unknown mode $mode" >&2; exit 2 ;;
esac
out="${2:-}"
psql=/Applications/Postgres.app/Contents/Versions/latest/bin/psql
db=pharos_draft_eval
work="$(mktemp -d "${TMPDIR:-/tmp}/draft-eval.XXXXXX")"
trap 'rm -rf "$work"' EXIT

"$psql" -h 127.0.0.1 -d postgres -Atqc "select 1 from pg_database where datname = '$db'" | grep -q 1 \
  || "$psql" -h 127.0.0.1 -d postgres -qc "create database $db"
"$psql" -h 127.0.0.1 -d "$db" -v ON_ERROR_STOP=1 -q -f scripts/draft-eval/schema.sql 2>/dev/null

# The catalogue as get_schema_columns reads it (information_schema data_type,
# primary keys from table_constraints).
"$psql" -h 127.0.0.1 -d "$db" -Atq > "$work/catalog.json" <<'SQL'
SELECT json_build_object('columns', coalesce(json_agg(json_build_object(
    'schema', c.table_schema, 'table', c.table_name, 'name', c.column_name,
    'dataType', c.data_type, 'isNullable', c.is_nullable = 'YES',
    'isPrimaryKey', pk.column_name IS NOT NULL, 'ordinal', c.ordinal_position)
    ORDER BY c.table_schema, c.table_name, c.ordinal_position), '[]'))
FROM information_schema.columns c
LEFT JOIN (
    SELECT kcu.table_schema, kcu.table_name, kcu.column_name
    FROM information_schema.table_constraints tc
    JOIN information_schema.key_column_usage kcu
      ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
    WHERE tc.constraint_type = 'PRIMARY KEY'
) pk ON pk.table_schema = c.table_schema AND pk.table_name = c.table_name AND pk.column_name = c.column_name
WHERE c.table_schema IN ('public', 'sales', 'hr');
SQL

common=(
  Pharos/Editor/SQLLexer.swift
  Pharos/Editor/SQLLexSnapshot.swift
  Pharos/Utilities/DestructiveSQLScanner.swift
  Pharos/Core/AuthoredLabelSanitizer.swift
  Pharos/Intelligence/GeneratedTextPolicy.swift
  Pharos/Intelligence/SQLDraftPolicy.swift
  scripts/draft-eval/Catalog.swift
  scripts/draft-eval/main.swift
)

case "$mode" in
  baseline)
    mkdir -p "$work/main"
    for f in SQLDraft.swift SQLDraftSchema.swift; do
      git show "main:Pharos/Intelligence/$f" > "$work/main/$f"
    done
    sources=("$work/main/SQLDraft.swift" "$work/main/SQLDraftSchema.swift"
             scripts/draft-eval/BaselineStubs.swift scripts/draft-eval/BaselineAdapter.swift)
    ;;
  pipeline|endpoint)
    # The facts query exactly as pharos-core sends it, once per schema.
    {
      printf '{'
      sep=''
      for s in public sales hr; do
        printf '%s"%s":' "$sep" "$s"
        sed "s/\$SCHEMA/'$s'/" pharos-core/src/db/sql/schema_draft_facts.sql | "$psql" -h 127.0.0.1 -d "$db" -Atq
        sep=','
      done
      printf '}'
    } > "$work/facts.json"
    export EVAL_FACTS="$work/facts.json"
    # Each table's DDL as View Table DDL's "+ Constraints" level writes it
    # (compose_table_ddl in pharos-core/src/commands/ddl.rs, from the two
    # queries of get_table_ddl_parts): columns, then constraints ordered
    # primary key, unique, check, foreign key, then PARTITION BY. A view is
    # written the same way, as its columns, which is what the app gets for one.
    if [ "${EVAL_DDL:-1}" != "0" ]; then
      "$psql" -h 127.0.0.1 -d "$db" -Atq > "$work/ddl.json" <<'SQL'
SELECT coalesce(json_object_agg(n.nspname || '.' || t.relname, json_build_object('ddl',
    'CREATE TABLE "' || replace(n.nspname, '"', '""') || '"."' || replace(t.relname, '"', '""') || E'" (\n'
    || array_to_string(ARRAY(
        SELECT '    "' || replace(a.attname, '"', '""') || '" ' || pg_catalog.format_type(a.atttypid, a.atttypmod)
            || CASE
                 WHEN a.attgenerated = 's' THEN
                     coalesce(' GENERATED ALWAYS AS (' || pg_get_expr(ad.adbin, ad.adrelid) || ') STORED', '')
                     || CASE WHEN a.attnotnull THEN ' NOT NULL' ELSE '' END
                 WHEN a.attidentity = 'a' THEN ' GENERATED ALWAYS AS IDENTITY'
                 WHEN a.attidentity = 'd' THEN ' GENERATED BY DEFAULT AS IDENTITY'
                 ELSE coalesce(' DEFAULT ' || pg_get_expr(ad.adbin, ad.adrelid), '')
                     || CASE WHEN a.attnotnull THEN ' NOT NULL' ELSE '' END
               END
        FROM pg_attribute a
        LEFT JOIN pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
        WHERE a.attrelid = t.oid AND a.attnum > 0 AND NOT a.attisdropped
        ORDER BY a.attnum)
      || ARRAY(
        SELECT '    CONSTRAINT "' || replace(con.conname, '"', '""') || '" ' || pg_get_constraintdef(con.oid)
        FROM pg_constraint con
        WHERE con.conrelid = t.oid AND con.contype IN ('p', 'u', 'c', 'f')
        ORDER BY CASE con.contype WHEN 'p' THEN 1 WHEN 'u' THEN 2 WHEN 'c' THEN 3 WHEN 'f' THEN 4 ELSE 5 END,
                 con.conname), E',\n')
    || E'\n)' || coalesce(' PARTITION BY ' || CASE WHEN t.relkind = 'p' THEN pg_get_partkeydef(t.oid) END, '') || ';')),
    '{}')
FROM pg_class t
JOIN pg_namespace n ON n.oid = t.relnamespace
WHERE n.nspname IN ('public', 'sales', 'hr') AND t.relkind IN ('r', 'p', 'v', 'm', 'f') AND NOT t.relispartition;
SQL
      export EVAL_DDL_FILE="$work/ddl.json"
    fi
    # The stub's copy of the safety sentences must match the app's.
    safety() { grep -A2 'static let sqlSafety' "$1" | tail -2; }
    [ "$(safety scripts/draft-eval/PipelineStubs.swift)" = "$(safety Pharos/Intelligence/IntelligenceSession.swift)" ] \
      || { echo "PipelineStubs.swift's sqlSafety has drifted from IntelligenceSession.swift" >&2; exit 1; }
    sources=(
      Pharos/Editor/SQLSegmentParser.swift
      Pharos/Editor/SQLStatementScope.swift
      Pharos/Models/SchemaDraftFacts.swift
      Pharos/Intelligence/SQLDraftSchema.swift
      Pharos/Intelligence/SQLDraftRanker.swift
      Pharos/Intelligence/SQLDraftPrompt.swift
      Pharos/Intelligence/SQLDraftChecker.swift
      Pharos/Intelligence/SQLDraftFixer.swift
      Pharos/Intelligence/ModelErrorKind.swift
      Pharos/Intelligence/IntelligenceBackend.swift
      Pharos/Intelligence/IntelligenceEndpoint.swift
      Pharos/Intelligence/EndpointIntelligenceBackend.swift
      Pharos/Intelligence/SQLDraft.swift
      scripts/draft-eval/PipelineStubs.swift
      scripts/draft-eval/PipelineAdapter.swift
    )
    ;;
esac

swiftc -O -o "$work/eval" "${common[@]}" "${sources[@]}"

EVAL_DB="$db" EVAL_CATALOG="$work/catalog.json" EVAL_CASES="${EVAL_CASES:-scripts/draft-eval/cases.json}" \
  EVAL_OUT="${out:-$work/results.json}" "$work/eval"

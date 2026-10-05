#!/bin/bash
# Grades "Describe a query" with the REAL on-device model against a fixture
# database. Not part of the unit sweep: it needs Apple Intelligence, a local
# Postgres.app, and minutes rather than seconds.
#
#   scripts/eval-sql-draft.sh baseline [out.json]   # the tool-calling drafter on main
#   scripts/eval-sql-draft.sh pipeline [out.json]   # the working tree's pipeline
#
# EVAL_ONLY=id1,id2 runs a subset; EVAL_TIMEOUT sets seconds per case.
# The fixture is (re)loaded into database pharos_draft_eval on every run.
set -euo pipefail
cd "$(dirname "$0")/.."

mode="${1:?usage: eval-sql-draft.sh baseline|pipeline [out.json]}"
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
  pipeline)
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
      Pharos/Intelligence/SQLDraft.swift
      scripts/draft-eval/PipelineStubs.swift
      scripts/draft-eval/PipelineAdapter.swift
    )
    ;;
  *) echo "unknown mode $mode" >&2; exit 2 ;;
esac

swiftc -O -o "$work/eval" "${common[@]}" "${sources[@]}"

EVAL_DB="$db" EVAL_CATALOG="$work/catalog.json" EVAL_CASES=scripts/draft-eval/cases.json \
  EVAL_OUT="${out:-$work/results.json}" "$work/eval"

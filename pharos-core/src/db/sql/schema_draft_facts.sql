-- What "Describe a query" adds to the cached catalogue for ONE schema:
-- foreign keys, enum labels, the real names of types information_schema
-- reports as USER-DEFINED or ARRAY, and short comments.
--
-- Names, types, keys and comments only. No column default and no CHECK
-- clause is read: both can hold literal values, and nothing this query
-- returns may carry one.
--
-- $SCHEMA is replaced by a quoted, escaped literal before the query is sent
-- (pharos-core/src/db/postgres.rs, schema_draft_facts_sql). Every "char"
-- catalogue column is cast to text where it is used: see tasks/lessons.md.
WITH rels AS (
    SELECT c.oid, c.relname
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = $SCHEMA
      AND c.relkind::text IN ('r', 'p', 'v', 'm', 'f')
      AND NOT c.relispartition
),
cols AS (
    SELECT r.relname AS table_name, a.attname, a.attnum, a.atttypid,
           pg_catalog.format_type(a.atttypid, a.atttypmod) AS type_name,
           left(pg_catalog.col_description(r.oid, a.attnum), 80) AS comment
    FROM rels r
    JOIN pg_catalog.pg_attribute a ON a.attrelid = r.oid
    JOIN pg_catalog.pg_type t ON t.oid = a.atttypid
    WHERE a.attnum > 0
      AND NOT a.attisdropped
      AND (t.typtype::text <> 'b'
           OR t.typcategory::text = 'A'
           OR pg_catalog.col_description(r.oid, a.attnum) IS NOT NULL)
),
fks AS (
    SELECT r.relname AS table_name, con.conname,
           (SELECT array_agg(a.attname::text ORDER BY k.ord)
              FROM unnest(con.conkey) WITH ORDINALITY AS k(attnum, ord)
              JOIN pg_catalog.pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum) AS columns,
           rn.nspname::text AS ref_schema,
           rc.relname::text AS ref_table,
           (SELECT array_agg(a.attname::text ORDER BY k.ord)
              FROM unnest(con.confkey) WITH ORDINALITY AS k(attnum, ord)
              JOIN pg_catalog.pg_attribute a ON a.attrelid = con.confrelid AND a.attnum = k.attnum) AS ref_columns
    FROM rels r
    JOIN pg_catalog.pg_constraint con ON con.conrelid = r.oid AND con.contype::text = 'f'
    JOIN pg_catalog.pg_class rc ON rc.oid = con.confrelid
    JOIN pg_catalog.pg_namespace rn ON rn.oid = rc.relnamespace
),
enums AS (
    SELECT pg_catalog.format_type(t.oid, NULL) AS type_name,
           ARRAY(SELECT e.enumlabel::text
                   FROM pg_catalog.pg_enum e
                  WHERE e.enumtypid = t.oid
                  ORDER BY e.enumsortorder
                  LIMIT 20) AS labels
    FROM pg_catalog.pg_type t
    WHERE t.typtype::text = 'e'
      AND t.oid IN (SELECT atttypid FROM cols)
)
SELECT json_build_object(
    'tableComments', (
        SELECT coalesce(json_object_agg(r.relname, left(pg_catalog.obj_description(r.oid, 'pg_class'), 80)), '{}'::json)
        FROM rels r
        WHERE pg_catalog.obj_description(r.oid, 'pg_class') IS NOT NULL),
    'columns', (
        SELECT coalesce(json_agg(json_build_object(
                   'table', table_name, 'name', attname, 'type', type_name, 'comment', comment)
                   ORDER BY table_name, attnum), '[]'::json)
        FROM cols),
    'foreignKeys', (
        SELECT coalesce(json_agg(json_build_object(
                   'table', table_name, 'columns', columns, 'refSchema', ref_schema,
                   'refTable', ref_table, 'refColumns', ref_columns)
                   ORDER BY table_name, conname), '[]'::json)
        FROM fks),
    'enums', (
        SELECT coalesce(json_agg(json_build_object('type', type_name, 'labels', labels)
                   ORDER BY type_name), '[]'::json)
        FROM enums)
)::text AS facts

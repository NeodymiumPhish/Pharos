-- Test schema for legacy inheritance partitioning in the Navigator.
--
-- Purpose: a tree shaped like the databases that prompted the feature — a
-- root, a table per year, a table per month, a table per day, joined only by
-- INHERITS, with no CHECK constraints and no partition bounds. It also holds
-- the two awkward cases: a declarative tree beside it, which must be
-- untouched, and a child of two parents.
--
-- Run:   psql -d <your_db> -f scripts/inherit-test-schema.sql
-- Drop:  DROP SCHEMA inherittest CASCADE;
--
-- Safe to re-run: it drops and recreates the schema each time.
--
-- What to look for in Settings ▸ Navigator ▸ Group inherited tables:
--   Off — all 12 tables list flat, as they always have, and `dns_log`
--         reports 0 rows, because the root itself holds none.
--   On  — `dns_log` lists alone with an INHERITS badge, "3 partitions" and
--         6 rows, which is what SELECT count(*) FROM dns_log returns. It
--         opens three levels deep. `events` is unchanged, with its RANGE
--         badge. `orphan_child` stays at the top level, because its parent
--         lives in another schema.
--
-- What to look for in Describe ▸ Clone Table (either way the setting points):
--   `events`     — "Include table rows" is DISABLED, with a note naming
--                  RANGE (seen). The copy comes out relkind 'p' with the same
--                  key and no partitions.
--   `dns_log`    — two row-scope radios. The default copies 0 rows (the root
--                  holds none of its own); "The whole tree, flattened" copies
--                  all 6. Either way `dns_log` still has exactly 3 direct
--                  children afterwards: the copy does not join the tree.
--   `dns_log_2013` — both at once: radios, AND the note that the copy will be
--                  standalone, not part of inherittest.dns_log's tree.
--   `settings_flat` — no note and no radios at all.

DROP SCHEMA IF EXISTS inherittest CASCADE;
DROP SCHEMA IF EXISTS inherittest_elsewhere CASCADE;
CREATE SCHEMA inherittest;
CREATE SCHEMA inherittest_elsewhere;

-- The legacy tree: root → year → month → day.
CREATE TABLE inherittest.dns_log (id bigint, seen timestamptz, name text);
CREATE TABLE inherittest.dns_log_2013 () INHERITS (inherittest.dns_log);
CREATE TABLE inherittest.dns_log_2014 () INHERITS (inherittest.dns_log);
CREATE TABLE inherittest.dns_log_201301 () INHERITS (inherittest.dns_log_2013);
CREATE TABLE inherittest.dns_log_20130101 () INHERITS (inherittest.dns_log_201301);
CREATE TABLE inherittest.dns_log_20130102 () INHERITS (inherittest.dns_log_201301);
CREATE TABLE inherittest.dns_log_20140101 () INHERITS (inherittest.dns_log_2014);

-- A child of TWO parents in the same tree. It is listed under both, and the
-- recursive walk must not count its rows twice in the root's total.
CREATE TABLE inherittest.dns_log_both ()
    INHERITS (inherittest.dns_log_2013, inherittest.dns_log_2014);

-- A third direct child of the root, so the root's count is 3 and not 2.
CREATE TABLE inherittest.dns_log_2015 () INHERITS (inherittest.dns_log);

-- A child whose parent is in ANOTHER schema. It must stay at the top level:
-- hiding it would leave no way to reach it.
CREATE TABLE inherittest_elsewhere.parent_over_there (id bigint);
CREATE TABLE inherittest.orphan_child ()
    INHERITS (inherittest_elsewhere.parent_over_there);

-- A declarative tree beside it, which must look exactly as it did before.
CREATE TABLE inherittest.events (id bigint, seen timestamptz) PARTITION BY RANGE (seen);
CREATE TABLE inherittest.events_2013 PARTITION OF inherittest.events
    FOR VALUES FROM ('2013-01-01') TO ('2014-01-01');
CREATE TABLE inherittest.events_2014 PARTITION OF inherittest.events
    FOR VALUES FROM ('2014-01-01') TO ('2015-01-01');

-- And a plain table with no relations at all.
CREATE TABLE inherittest.settings_flat (id bigint, label text);

INSERT INTO inherittest.dns_log_20130101 (id) SELECT generate_series(1, 3);
INSERT INTO inherittest.dns_log_20130102 (id) SELECT generate_series(4, 5);
INSERT INTO inherittest.dns_log_20140101 (id) VALUES (6);
INSERT INTO inherittest.events_2013 (id, seen) VALUES (1, '2013-06-01');
INSERT INTO inherittest.settings_flat (id, label) VALUES (1, 'alone');

-- Row estimates come from pg_class.reltuples, which is -1 until this runs.
ANALYZE inherittest.dns_log;
ANALYZE inherittest.dns_log_2013;
ANALYZE inherittest.dns_log_2014;
ANALYZE inherittest.dns_log_2015;
ANALYZE inherittest.dns_log_201301;
ANALYZE inherittest.dns_log_20130101;
ANALYZE inherittest.dns_log_20130102;
ANALYZE inherittest.dns_log_20140101;
ANALYZE inherittest.dns_log_both;
ANALYZE inherittest.orphan_child;
ANALYZE inherittest.events;
ANALYZE inherittest.settings_flat;

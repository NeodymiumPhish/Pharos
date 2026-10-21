# The DuckDB extensions Pharos links statically (scripts/build-duckdb.sh).
#
# A built-in extension needs no download and no dlopen, which the hardened,
# ad-hoc signed app cannot do (library validation refuses a library from
# another signer). Out-of-tree commits are the ones DuckDB v1.5.6's own CI
# pins (.github/config/extensions/*.cmake at that tag).

# In DuckDB's tree.
duckdb_extension_load(core_functions)
duckdb_extension_load(parquet)
duckdb_extension_load(json)
duckdb_extension_load(icu)
duckdb_extension_load(autocomplete)

# INET / CIDR types and functions.
duckdb_extension_load(inet
    GIT_URL https://github.com/duckdb/duckdb-inet
    GIT_TAG fe7f60bb60245197680fb07ecd1629a1dc3d91c8
    INCLUDE_DIR src/include
)

# Full-text search (PRAGMA create_fts_index, match_bm25). DuckDB's CI builds it
# DONT_LINK; it has no dependencies, so Pharos links it.
duckdb_extension_load(fts
    GIT_URL https://github.com/duckdb/duckdb-fts
    GIT_TAG 6814ec9a7d5fd63500176507262b0dbf7cea0095
    INCLUDE_DIR extension/fts/include
)

# read_xlsx and COPY ... TO 'x.xlsx'. Needs expat and minizip-ng (vcpkg).
duckdb_extension_load(excel
    GIT_URL https://github.com/duckdb/duckdb-excel
    GIT_TAG f4c72b5ef04a03b3a78a95b5a2ee94ba93e3178d
    INCLUDE_DIR src/excel/include
)

# ATTACH 'x.sqlite' (TYPE sqlite), sqlite_scan.
duckdb_extension_load(sqlite_scanner
    GIT_URL https://github.com/duckdb/duckdb-sqlite
    GIT_TAG 5274128259f73166c1f37f01190a4601f84c5525
    SUBMODULES database-connector
)

# SPIKE (spike/duckdb-httpfs-postgres): remote files and PostgreSQL.

# read_csv/read_parquet over http(s)://, s3://, gcs://, r2://. DuckDB's CI
# applies one patch, which only skips a test, so none is applied here.
duckdb_extension_load(httpfs
    GIT_URL https://github.com/duckdb/duckdb-httpfs
    GIT_TAG 4bc690dba4496c765777a0269d48fdbaff7cdc11
)

# ATTACH '<libpq connection string>' (TYPE postgres), postgres_scan. DuckDB's
# CI builds it DONT_LINK; the spike links it.
duckdb_extension_load(postgres_scanner
    GIT_URL https://github.com/duckdb/duckdb-postgres
    GIT_TAG 318dabb2474fc3789b0199301a2e661e19c1b4fc
    SUBMODULES database-connector
)

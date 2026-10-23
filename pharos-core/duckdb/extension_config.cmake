# The DuckDB extensions Pharos links statically (scripts/build-duckdb.sh).
#
# A built-in extension needs no download and no dlopen, which the hardened,
# ad-hoc signed app cannot do (library validation refuses a library from
# another signer). Out-of-tree commits, patches and include folders are the
# ones DuckDB v2.0.0's own CI uses (.github/config/extensions/*.cmake at that
# tag); APPLY_PATCHES applies .github/patches/extensions/<name>/ from the
# DuckDB tree, the compile fixes for 2.0's API.
#
# Since 2.0 a loaded extension is only built: duckdb_extension_statically_link
# at the end names the ones Pharos links, and build-duckdb.sh reads that list
# to generate the loader that registers them (duckdb_register_static_extensions,
# called by pharos-core before it opens a database).

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
    APPLY_PATCHES
)

# Full-text search (PRAGMA create_fts_index, match_bm25). No dependencies.
duckdb_extension_load(fts
    GIT_URL https://github.com/duckdb/duckdb-fts
    GIT_TAG 2266e67d01c737cb65114e77c7c672e58869a635
    APPLY_PATCHES
)

# read_xlsx and COPY ... TO 'x.xlsx'. Needs expat and minizip-ng (vcpkg).
duckdb_extension_load(excel
    GIT_URL https://github.com/duckdb/duckdb-excel
    GIT_TAG 81bb84b115b97cc4edec4827714cac80da0127e1
    INCLUDE_DIR src/excel/include
)

# ATTACH 'x.sqlite' (TYPE sqlite), sqlite_scan.
duckdb_extension_load(sqlite_scanner
    GIT_URL https://github.com/duckdb/duckdb-sqlite
    GIT_TAG e223dc01493414cef6d5960744f1e048d59fc592
    SUBMODULES database-connector
)

# read_csv/read_parquet over http(s)://, s3://, gcs://, r2://. Needs curl and
# OpenSSL (vcpkg).
duckdb_extension_load(httpfs
    GIT_URL https://github.com/duckdb/duckdb-httpfs
    GIT_TAG 77392a72077a85897db2519fae11e2c0da972b8a
)

# ATTACH '<libpq connection string>' (TYPE postgres), postgres_scan. Needs
# libpq (vcpkg).
duckdb_extension_load(postgres_scanner
    GIT_URL https://github.com/duckdb/duckdb-postgres
    GIT_TAG c0f5a3c0c4b68b02afbf669d36d7f0e503985c88
    SUBMODULES database-connector
)

# What Pharos links and registers, in load order. One name per line: the
# build script reads this list.
duckdb_extension_statically_link(
    core_functions
    parquet
    json
    icu
    autocomplete
    inet
    fts
    excel
    sqlite_scanner
    httpfs
    postgres_scanner
)

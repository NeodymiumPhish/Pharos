# Security

## What Pharos stores

- Connection passwords and SSH secrets are in the macOS Keychain, not in Pharos's own database.
- Query history replaces passwords and keys in SQL text with `'********'` (for example `ALTER ROLE … PASSWORD '…'`, `CREATE SECRET (… SECRET '…')`, and `password=` in a connection string). Saved Sessions keep the SQL exactly as you wrote it.
- DuckDB secrets live in memory only. Pharos refuses `CREATE PERSISTENT SECRET`, because DuckDB writes those secrets to disk in plain text.
- When a DuckDB tab attaches a PostgreSQL connection, Pharos gives DuckDB the password in a temporary secret. The password is not in SQL text.
- The API key of a custom AI endpoint is in the macOS Keychain, not in Pharos's settings. An app-data export does not include it.

## What Pharos sends

- By default, nothing. The intelligence features use Apple's on-device model, and Pharos opens no network connection for them.
- With a custom AI endpoint chosen in Settings ▸ Intelligence, each feature sends that endpoint the text it works from: your SQL, the names and types of the tables and columns it mentions, error messages and query plans. Describing a query also sends the definitions (DDL) of the tab's tables, which include column defaults and check constraints. Describing a change to a card's query sends that query's SQL as well. SQL and plans can contain values you typed. No feature sends the rows of a result.
- Pharos sends to an endpoint on another machine only after you allow that host, in a sheet that says what is sent. Changing the address to another host needs a new permission. An endpoint on this Mac (`localhost`, `127.0.0.1`, `::1`) needs none.
- The endpoint's address must be `https://`, except for an endpoint on this Mac. Pharos does not follow redirects from it, so the API key and the prompt reach only the host you entered.
- While a custom endpoint is chosen, the on-device model never answers in its place, and the reverse.
- Pharos does not log prompts, answers or the API key.

## Bundled libraries

Pharos compiles these C and C++ libraries into the app. A security fix in one of them reaches users only in a new Pharos release.

| Library | Used for | Pinned in |
|---|---|---|
| OpenSSL | TLS for DuckDB's `httpfs` and `postgres_scanner` | `VCPKG_TAG` in `scripts/build-duckdb.sh` |
| curl | HTTP for DuckDB's `httpfs` | `VCPKG_TAG` |
| libpq | DuckDB's `postgres_scanner` | `VCPKG_TAG` |
| lz4, expat, minizip-ng | DuckDB's extensions | `VCPKG_TAG` |
| DuckDB and its extensions | the DuckDB engine | `DUCKDB_TAG` in `scripts/build-duckdb.sh`, commits in `pharos-core/duckdb/extension_config.cmake` |

The PostgreSQL connections of Pharos itself do not use OpenSSL: they use the macOS Security framework through `sqlx`.

### Before each release

1. Run `scripts/check-vendored-versions.sh`. It compares each pinned version with the latest upstream release (for libpq, the latest minor of the same major).
2. If OpenSSL, curl or libpq is behind, read the release notes of the newer version. Treat a security fix as a reason to update before the release.

### Update OpenSSL, curl or libpq

1. Set `VCPKG_TAG` in `scripts/build-duckdb.sh` to a vcpkg release that has the fixed version (its `ports/<library>/vcpkg.json`).
2. Delete `pharos-core/target/duckdb-build/vcpkg`, so the script clones the new tag.
3. Run `scripts/build-duckdb.sh arm64` and `scripts/build-duckdb.sh x86_64`.
4. Run the Rust tests: `cd pharos-core && cargo test --release`.
5. Run `scripts/gen-third-party-notices.sh` and commit the notices with the change.
6. Release a new version of Pharos.

A security fix in DuckDB itself or in one of its extensions follows the same steps with `DUCKDB_TAG` and the extension commits that DuckDB's release pins (`.github/config/extensions/*.cmake` in the DuckDB repository).

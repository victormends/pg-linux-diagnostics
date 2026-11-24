# pg-linux-diagnostics

Linux Bash and SQL diagnostic toolkit plus an inactive replication-slot guard for PostgreSQL.
Built for direct DBRE/SRE incident triage with zero PowerShell or external agent dependencies, using read-only `psql` transactions and parameterized slot cleanup.
Every push runs `shellcheck` and an end-to-end suite against a live `postgres:16-alpine` container exercising WAL retention slots, row lock chains, `pg_toast` growth, `scram-sha-256` HBA checks, and `EXPLAIN (ANALYZE, BUFFERS)`.

## Quick Start with Docker

```bash
docker compose up -d --wait

export PGHOST=127.0.0.1
export PGPORT=5432
export PGUSER=diag
export PGPASSWORD=diag_test_password
export PGDATABASE=diagdb

./bin/pg-diag.sh --check all --format table
./bin/pg-slot-guard.sh --threshold-mb 1024
```

Run the full live integration suite:

```bash
./tests/integration.sh
docker compose down -v
```

## CLI Reference

### `bin/pg-diag.sh`

Runs read-only diagnostic queries (`default_transaction_read_only=on`) using standard libpq environment variables (`PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE`, `PGPASSWORD`, `.pgpass`).

- `--check all|slots|locks|toast|auth` (default: `all`)
- `--format table|csv|json` (default: `table`)
- `-h`, `--help`

Examples:

```bash
./bin/pg-diag.sh --check slots --format json
./bin/pg-diag.sh --check locks --format table
./bin/pg-diag.sh --check toast --format csv
./bin/pg-diag.sh --check auth --format json
```

### `bin/pg-slot-guard.sh`

Finds inactive replication slots retaining WAL above a MiB threshold. Runs in dry-run mode by default.

- `--threshold-mb <N>` (default: `1024`, integer `>= 0`)
- `--slot <name>` (optional exact slot filter)
- `--apply-drop` (explicit opt-in to execute `pg_drop_replication_slot()`)
- `-h`, `--help`

Examples:

```bash
# Dry-run preview (default)
./bin/pg-slot-guard.sh --threshold-mb 1024

# Target a single inactive slot and drop it
./bin/pg-slot-guard.sh --threshold-mb 512 --slot analytics_cdc --apply-drop
```

## What CI Verifies Live

- **Static checks**: `shellcheck bin/*.sh tests/*.sh` passes with zero warnings.
- **WAL & slot guard**: Creates an inactive `test_decoding` slot (`orphaned_test_slot`), generates WAL + `pg_switch_wal()`, verifies `pg-diag.sh --check slots --format json` detects `retained_wal_bytes > 0`, confirms dry-run preserves the slot, and confirms `--apply-drop` removes it.
- **Lock wait chains**: Forces a real row-level `FOR UPDATE` contention between two `psql` sessions and verifies `pg_blocking_pids()` reports `blocker_pid` and `blocked_pid`.
- **TOAST vs heap growth**: Inserts 20 incompressible >64 KB payloads into `diag_toast_test` and confirms `toast_bytes > 0` while excluding system schemas.
- **Auth & HBA posture**: Verifies `password_encryption == "scram-sha-256"` alongside `pg_hba_file_rules` risk classification.
- **Plan regression benchmark**: Loads 100,000 rows into `diag_events`, compares `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` before and after indexing `(tenant_id, created_at)`, and asserts the sequential scan is replaced by an index scan with fewer shared blocks and lower execution time.

## Safety Boundaries

- `pg-diag.sh` sets `PGOPTIONS="-c default_transaction_read_only=on"` so diagnostic queries cannot mutate database state.
- `pg-slot-guard.sh` is dry-run by default, passes slot names via parameterized `psql -v` variables (`:'slot_name'`) to prevent SQL injection, and enforces `active = false` in both discovery and drop SQL.
- Neither script ever accesses `pg_wal` on disk or invokes `pg_resetwal`.

## License

[MIT](LICENSE)

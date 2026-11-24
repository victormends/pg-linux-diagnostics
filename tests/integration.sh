#!/usr/bin/env bash
set -euo pipefail

# Live integration suite for pg-linux-diagnostics against PostgreSQL 16.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
BIN_DIR="${ROOT_DIR}/bin"

export PGHOST="${PGHOST:-127.0.0.1}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-diag}"
export PGPASSWORD="${PGPASSWORD:-diag_test_password}"
export PGDATABASE="${PGDATABASE:-diagdb}"

BLOCKER_BG_PID=""
BLOCKED_BG_PID=""

cleanup() {
    if [[ -n "$BLOCKED_BG_PID" ]]; then
        kill "$BLOCKED_BG_PID" 2>/dev/null || true
        wait "$BLOCKED_BG_PID" 2>/dev/null || true
        BLOCKED_BG_PID=""
    fi
    if [[ -n "$BLOCKER_BG_PID" ]]; then
        kill "$BLOCKER_BG_PID" 2>/dev/null || true
        wait "$BLOCKER_BG_PID" 2>/dev/null || true
        BLOCKER_BG_PID=""
    fi
    psql -X -v ON_ERROR_STOP=0 -q -c "
        SELECT pg_terminate_backend(pid)
        FROM pg_stat_activity
        WHERE pid <> pg_backend_pid()
          AND query LIKE '%diag_lock_test%';
        DROP TABLE IF EXISTS diag_lock_test;
        DROP TABLE IF EXISTS diag_toast_test;
        DROP TABLE IF EXISTS diag_events;
        DROP TABLE IF EXISTS diag_slot_wal_gen;
        SELECT pg_drop_replication_slot(slot_name)
        FROM pg_catalog.pg_replication_slots
        WHERE slot_name = 'orphaned_test_slot';
    " >/dev/null 2>&1 || true
}

trap cleanup EXIT

require_cmd() {
    local cmd
    cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        printf 'ERROR: Required command not found: %s\n' "$cmd" >&2
        exit 1
    fi
}

assert_cli_validation() {
    local rc=0
    "$BIN_DIR/pg-diag.sh" --check bogus >/dev/null 2>&1 || rc=$?
    if [[ "$rc" -ne 2 ]]; then
        printf 'FAIL: expected exit code 2 for invalid --check, got %s\n' "$rc" >&2
        exit 1
    fi

    rc=0
    "$BIN_DIR/pg-diag.sh" --format bogus >/dev/null 2>&1 || rc=$?
    if [[ "$rc" -ne 2 ]]; then
        printf 'FAIL: expected exit code 2 for invalid --format, got %s\n' "$rc" >&2
        exit 1
    fi

    rc=0
    "$BIN_DIR/pg-slot-guard.sh" --threshold-mb -1 >/dev/null 2>&1 || rc=$?
    if [[ "$rc" -ne 2 ]]; then
        printf 'FAIL: expected exit code 2 for invalid --threshold-mb, got %s\n' "$rc" >&2
        exit 1
    fi
    printf '[PASS] CLI argument validation (exit code 2)\n'
}

test_slots_and_slot_guard() {
    local slots_json
    local dry_out
    local drop_out
    local remaining

    psql -X -v ON_ERROR_STOP=1 -q -c "
        SELECT pg_drop_replication_slot(slot_name)
        FROM pg_catalog.pg_replication_slots
        WHERE slot_name = 'orphaned_test_slot';
        SELECT pg_create_logical_replication_slot('orphaned_test_slot', 'test_decoding');
        CREATE TABLE diag_slot_wal_gen (id serial, pad text);
        INSERT INTO diag_slot_wal_gen (pad)
        SELECT repeat('w', 1024) FROM generate_series(1, 500);
        SELECT pg_switch_wal();
        DROP TABLE diag_slot_wal_gen;
    " >/dev/null

    slots_json=$("$BIN_DIR/pg-diag.sh" --check slots --format json)
    if ! printf '%s\n' "$slots_json" | jq -e 'any(.[]; .slot_name == "orphaned_test_slot" and .active == false and (.retained_wal_bytes | tonumber) > 0)' >/dev/null; then
        printf 'FAIL: slots JSON did not contain inactive orphaned_test_slot with retained_wal_bytes > 0:\n%s\n' "$slots_json" >&2
        exit 1
    fi

    dry_out=$("$BIN_DIR/pg-slot-guard.sh" --threshold-mb 0)
    if [[ "$dry_out" != *"[DRY-RUN]"* || "$dry_out" != *"orphaned_test_slot"* ]]; then
        printf 'FAIL: slot-guard dry-run output unexpected:\n%s\n' "$dry_out" >&2
        exit 1
    fi

    remaining=$(psql -X -v ON_ERROR_STOP=1 -A -t -q -c "SELECT count(*) FROM pg_catalog.pg_replication_slots WHERE slot_name = 'orphaned_test_slot';")
    if [[ "$remaining" -ne 1 ]]; then
        printf 'FAIL: dry-run unexpectedly removed orphaned_test_slot (remaining=%s)\n' "$remaining" >&2
        exit 1
    fi

    drop_out=$("$BIN_DIR/pg-slot-guard.sh" --threshold-mb 0 --apply-drop)
    if [[ "$drop_out" != *"[DROPPED]"* || "$drop_out" != *"orphaned_test_slot"* ]]; then
        printf 'FAIL: slot-guard --apply-drop output unexpected:\n%s\n' "$drop_out" >&2
        exit 1
    fi

    remaining=$(psql -X -v ON_ERROR_STOP=1 -A -t -q -c "SELECT count(*) FROM pg_catalog.pg_replication_slots WHERE slot_name = 'orphaned_test_slot';")
    if [[ "$remaining" -ne 0 ]]; then
        printf 'FAIL: orphaned_test_slot still exists after --apply-drop (remaining=%s)\n' "$remaining" >&2
        exit 1
    fi
    printf '[PASS] Test 1: replication slots + slot-guard dry-run/apply-drop\n'
}

test_lock_wait_chains() {
    local locks_json=""
    local detected="false"

    psql -X -v ON_ERROR_STOP=1 -q -c "
        DROP TABLE IF EXISTS diag_lock_test;
        CREATE TABLE diag_lock_test (id int PRIMARY KEY, val text NOT NULL);
        INSERT INTO diag_lock_test (id, val) VALUES (1, 'initial');
    "

    psql -X -v ON_ERROR_STOP=1 -q -c "
        BEGIN;
        SELECT id FROM diag_lock_test WHERE id = 1 FOR UPDATE;
        SELECT pg_sleep(6);
        COMMIT;
    " >/dev/null 2>&1 &
    BLOCKER_BG_PID=$!

    sleep 0.5

    psql -X -v ON_ERROR_STOP=1 -q -c "
        UPDATE diag_lock_test SET val = 'blocked' WHERE id = 1;
    " >/dev/null 2>&1 &
    BLOCKED_BG_PID=$!

    for _ in 1 2 3 4 5 6 7 8 9 10; do
        locks_json=$("$BIN_DIR/pg-diag.sh" --check locks --format json)
        if printf '%s\n' "$locks_json" | jq -e 'length >= 1 and (.[0].blocker_pid | tonumber) > 0 and (.[0].blocked_pid | tonumber) > 0' >/dev/null 2>&1; then
            detected="true"
            break
        fi
        sleep 0.5
    done

    kill "$BLOCKED_BG_PID" 2>/dev/null || true
    wait "$BLOCKED_BG_PID" 2>/dev/null || true
    BLOCKED_BG_PID=""

    kill "$BLOCKER_BG_PID" 2>/dev/null || true
    wait "$BLOCKER_BG_PID" 2>/dev/null || true
    BLOCKER_BG_PID=""

    psql -X -v ON_ERROR_STOP=0 -q -c "
        SELECT pg_terminate_backend(pid)
        FROM pg_stat_activity
        WHERE pid <> pg_backend_pid()
          AND query LIKE '%diag_lock_test%';
        DROP TABLE IF EXISTS diag_lock_test;
    " >/dev/null 2>&1 || true

    if [[ "$detected" != "true" ]]; then
        printf 'FAIL: lock wait chain was not detected within 5s. Last output:\n%s\n' "$locks_json" >&2
        exit 1
    fi
    printf '[PASS] Test 2: live lock wait chains (pg_blocking_pids)\n'
}

test_toast_growth() {
    local toast_json

    psql -X -v ON_ERROR_STOP=1 -q -c "
        DROP TABLE IF EXISTS diag_toast_test;
        CREATE TABLE diag_toast_test (
            id bigserial PRIMARY KEY,
            payload text NOT NULL
        );
        INSERT INTO diag_toast_test (payload)
        SELECT (
            SELECT string_agg(md5(random()::text), '')
            FROM generate_series(1, 2200)
            WHERE g > 0
        )
        FROM generate_series(1, 20) AS g;
    "

    toast_json=$("$BIN_DIR/pg-diag.sh" --check toast --format json)
    if ! printf '%s\n' "$toast_json" | jq -e 'any(.[]; .table_name == "diag_toast_test" and (.toast_bytes | tonumber) > 0)' >/dev/null; then
        printf 'FAIL: diag_toast_test missing or toast_bytes == 0:\n%s\n' "$toast_json" >&2
        exit 1
    fi

    if ! printf '%s\n' "$toast_json" | jq -e 'all(.[]; .schema_name != "pg_catalog" and .schema_name != "information_schema" and .schema_name != "pg_toast")' >/dev/null; then
        printf 'FAIL: system schema leaked into toast growth output:\n%s\n' "$toast_json" >&2
        exit 1
    fi

    psql -X -v ON_ERROR_STOP=1 -q -c "DROP TABLE IF EXISTS diag_toast_test;"
    printf '[PASS] Test 3: TOAST and table storage growth\n'
}

test_auth_audit() {
    local auth_json

    auth_json=$("$BIN_DIR/pg-diag.sh" --check auth --format json)
    if ! printf '%s\n' "$auth_json" | jq -e 'length >= 1 and all(.[]; .password_encryption == "scram-sha-256") and any(.[]; .line_number != null and .auth_method != null)' >/dev/null; then
        printf 'FAIL: auth audit check failed:\n%s\n' "$auth_json" >&2
        exit 1
    fi
    printf '[PASS] Test 4: auth and pg_hba_file_rules audit (scram-sha-256)\n'
}

test_explain_analyze() {
    local before_json
    local after_json
    local before_node
    local after_node
    local before_ms
    local after_ms
    local before_blocks
    local after_blocks

    psql -X -v ON_ERROR_STOP=1 -q -c "
        DROP TABLE IF EXISTS diag_events;
        CREATE TABLE diag_events (
            id bigserial PRIMARY KEY,
            tenant_id int NOT NULL,
            created_at timestamptz NOT NULL,
            payload text NOT NULL
        );
        INSERT INTO diag_events (tenant_id, created_at, payload)
        SELECT
            (g % 500) + 1,
            TIMESTAMPTZ '2026-01-01 00:00:00+00' + ((g % 10000) * INTERVAL '1 minute'),
            md5(g::text) || '-' || repeat('a', 64)
        FROM generate_series(1, 100000) AS g;
        ANALYZE diag_events;
    "

    before_json=$(psql -X -v ON_ERROR_STOP=1 -A -t -q -c "
        SET max_parallel_workers_per_gather = 0;
        EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
        SELECT id, tenant_id, created_at
        FROM diag_events
        WHERE tenant_id = 42
          AND created_at >= TIMESTAMPTZ '2026-01-06 00:00:00+00';
    ")

    before_node=$(printf '%s\n' "$before_json" | jq -r '.[0].Plan["Node Type"]')
    before_ms=$(printf '%s\n' "$before_json" | jq -r '.[0]["Execution Time"]')
    before_blocks=$(printf '%s\n' "$before_json" | jq -r '(.[0].Plan["Shared Hit Blocks"] // 0) + (.[0].Plan["Shared Read Blocks"] // 0)')

    if [[ "$before_node" != "Seq Scan" ]]; then
        printf 'FAIL: expected Seq Scan before index, got %s\n' "$before_node" >&2
        exit 1
    fi

    psql -X -v ON_ERROR_STOP=1 -q -c "
        CREATE INDEX idx_diag_events_tenant_created
            ON diag_events (tenant_id, created_at);
        ANALYZE diag_events;
    "

    after_json=$(psql -X -v ON_ERROR_STOP=1 -A -t -q -c "
        SET max_parallel_workers_per_gather = 0;
        EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
        SELECT id, tenant_id, created_at
        FROM diag_events
        WHERE tenant_id = 42
          AND created_at >= TIMESTAMPTZ '2026-01-06 00:00:00+00';
    ")

    after_node=$(printf '%s\n' "$after_json" | jq -r '.[0].Plan["Node Type"]')
    after_ms=$(printf '%s\n' "$after_json" | jq -r '.[0]["Execution Time"]')
    after_blocks=$(printf '%s\n' "$after_json" | jq -r '(.[0].Plan["Shared Hit Blocks"] // 0) + (.[0].Plan["Shared Read Blocks"] // 0)')

    if ! printf '%s\n' "$after_json" | jq -e '
        [.. | .["Node Type"]? // empty]
        | (any(. == "Seq Scan" or . == "Parallel Seq Scan") | not)
          and any(. == "Index Scan" or . == "Index Only Scan" or . == "Bitmap Heap Scan" or . == "Bitmap Index Scan")
    ' >/dev/null; then
        printf 'FAIL: expected index scan and no Seq Scan after index creation:\n%s\n' "$after_json" >&2
        exit 1
    fi

    if (( after_blocks >= before_blocks )); then
        printf 'FAIL: expected lower shared blocks after index (%s vs %s)\n' "$after_blocks" "$before_blocks" >&2
        exit 1
    fi

    if ! awk -v a="$after_ms" -v b="$before_ms" 'BEGIN { exit !(a < b) }'; then
        printf 'FAIL: expected faster execution after index (%s ms vs %s ms)\n' "$after_ms" "$before_ms" >&2
        exit 1
    fi

    psql -X -v ON_ERROR_STOP=1 -q -c "DROP TABLE IF EXISTS diag_events;"

    printf '\nEXPLAIN (ANALYZE, BUFFERS) Benchmark Summary (100,000 rows):\n'
    printf '%-10s | %-20s | %-15s | %-15s\n' "Phase" "Top Plan Node" "Exec Time (ms)" "Shared Blocks"
    printf '%-10s-+-%-20s-+-%-15s-+-%-15s\n' "----------" "--------------------" "---------------" "---------------"
    printf '%-10s | %-20s | %-15s | %-15s\n' "Before" "$before_node" "$before_ms" "$before_blocks"
    printf '%-10s | %-20s | %-15s | %-15s\n\n' "After" "$after_node" "$after_ms" "$after_blocks"
    printf '[PASS] Test 5: EXPLAIN (ANALYZE, BUFFERS) before/after composite index\n'
}

main() {
    require_cmd psql
    require_cmd jq

    # Verify CLI --check all and --format csv/table work end-to-end too.
    "$BIN_DIR/pg-diag.sh" --check all --format json | jq -e 'has("slots") and has("locks") and has("toast") and has("auth")' >/dev/null
    "$BIN_DIR/pg-diag.sh" --check auth --format csv >/dev/null
    "$BIN_DIR/pg-diag.sh" --check auth --format table >/dev/null

    assert_cli_validation
    test_slots_and_slot_guard
    test_lock_wait_chains
    test_toast_growth
    test_auth_audit
    test_explain_analyze

    printf 'ALL INTEGRATION TESTS PASSED\n'
}

main "$@"

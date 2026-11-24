#!/usr/bin/env bash
set -euo pipefail

# pg-slot-guard.sh - Safe inactive PostgreSQL replication slot guard.
# Dry-run by default. Never drops active slots, never touches pg_wal, never runs pg_resetwal.

usage() {
    cat <<'EOF'
Usage: pg-slot-guard.sh [OPTIONS]

Inspect inactive PostgreSQL replication slots exceeding a retained WAL threshold.
Runs in dry-run mode by default unless --apply-drop is explicitly supplied.

Options:
  --threshold-mb <N>  Minimum retained WAL in MiB to flag a slot (default: 1024)
  --slot <name>       Optional exact replication slot name filter
  --apply-drop        Drop matching inactive slots via pg_drop_replication_slot()
  -h, --help          Show this help message and exit

Safety boundaries:
  - Never drops slots where active = true
  - Never accesses pg_wal on disk
  - Never invokes pg_resetwal

Environment:
  PGHOST              PostgreSQL host (default: 127.0.0.1)
  PGPORT              PostgreSQL port (default: 5432)
  PGUSER              PostgreSQL user (default: postgres)
  PGDATABASE          PostgreSQL database (default: postgres)
  PGPASSWORD          Optional password (or configure ~/.pgpass)
EOF
}

die_usage() {
    local msg
    msg="$1"
    printf 'ERROR: %s\n\n' "$msg" >&2
    usage >&2
    exit 2
}

main() {
    local threshold_mb="1024"
    local target_slot=""
    local apply_drop="false"
    local threshold_bytes
    local list_sql
    local drop_sql
    local candidates
    local slot_name
    local plugin
    local slot_type
    local db_name
    local retained_bytes
    local retained_pretty
    local drop_result
    local found_count=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --threshold-mb)
                if [[ $# -lt 2 || -z "$2" ]]; then
                    die_usage "--threshold-mb requires an integer >= 0"
                fi
                threshold_mb="$2"
                shift 2
                ;;
            --threshold-mb=*)
                threshold_mb="${1#*=}"
                if [[ -z "$threshold_mb" ]]; then
                    die_usage "--threshold-mb requires an integer >= 0"
                fi
                shift
                ;;
            --slot)
                if [[ $# -lt 2 || -z "$2" ]]; then
                    die_usage "--slot requires a slot name"
                fi
                target_slot="$2"
                shift 2
                ;;
            --slot=*)
                target_slot="${1#*=}"
                if [[ -z "$target_slot" ]]; then
                    die_usage "--slot requires a slot name"
                fi
                shift
                ;;
            --apply-drop)
                apply_drop="true"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die_usage "Unknown argument: $1"
                ;;
        esac
    done

    if [[ ! "$threshold_mb" =~ ^[0-9]+$ ]]; then
        die_usage "Invalid --threshold-mb value '${threshold_mb}'. Must be an integer >= 0."
    fi

    if ! command -v psql >/dev/null 2>&1; then
        printf 'ERROR: psql binary not found in PATH.\n' >&2
        exit 1
    fi

    export PGHOST="${PGHOST:-127.0.0.1}"
    export PGPORT="${PGPORT:-5432}"
    export PGUSER="${PGUSER:-postgres}"
    export PGDATABASE="${PGDATABASE:-postgres}"

    threshold_bytes=$(( threshold_mb * 1048576 ))

    list_sql="SELECT
    s.slot_name,
    COALESCE(NULLIF(s.plugin, ''), '-'),
    s.slot_type,
    COALESCE(NULLIF(s.database, ''), '-'),
    COALESCE(
        pg_wal_lsn_diff(
            pg_current_wal_lsn(),
            COALESCE(s.restart_lsn, s.confirmed_flush_lsn)
        ),
        0
    )::bigint AS retained_wal_bytes,
    pg_size_pretty(
        COALESCE(
            pg_wal_lsn_diff(
                pg_current_wal_lsn(),
                COALESCE(s.restart_lsn, s.confirmed_flush_lsn)
            ),
            0
        )
    ) AS retained_wal_pretty
FROM pg_catalog.pg_replication_slots AS s
WHERE s.active = false
  AND COALESCE(
        pg_wal_lsn_diff(
            pg_current_wal_lsn(),
            COALESCE(s.restart_lsn, s.confirmed_flush_lsn)
        ),
        0
    )::bigint >= :'threshold_bytes'::bigint
  AND (:'target_slot' = '' OR s.slot_name = :'target_slot')
ORDER BY retained_wal_bytes DESC, s.slot_name ASC;"

    candidates=$(psql -X -v ON_ERROR_STOP=1 -A -t -q -F $'\t' \
        -v threshold_bytes="$threshold_bytes" \
        -v target_slot="$target_slot" \
        <<< "$list_sql")

    if [[ -z "$candidates" ]]; then
        printf '[OK] No inactive replication slots exceed %s MiB threshold.\n' "$threshold_mb"
        exit 0
    fi

    drop_sql="SELECT s.slot_name, pg_drop_replication_slot(:'slot_name')
FROM pg_catalog.pg_replication_slots AS s
WHERE s.slot_name = :'slot_name'
  AND s.active = false;"

    while IFS=$'\t' read -r slot_name plugin slot_type db_name retained_bytes retained_pretty; do
        if [[ -z "$slot_name" ]]; then
            continue
        fi
        found_count=$(( found_count + 1 ))
        if [[ "$apply_drop" == "true" ]]; then
            drop_result=$(psql -X -v ON_ERROR_STOP=1 -A -t -q -F $'\t' \
                -v slot_name="$slot_name" \
                <<< "$drop_sql")
            if [[ -n "$drop_result" ]]; then
                printf '[DROPPED] slot=%s type=%s plugin=%s db=%s retained=%s (%s bytes)\n' \
                    "$slot_name" "$slot_type" "$plugin" "$db_name" "$retained_pretty" "$retained_bytes"
            else
                printf '[SKIPPED] slot=%s became active or no longer exists\n' "$slot_name"
            fi
        else
            printf '[DRY-RUN] would drop inactive slot=%s type=%s plugin=%s db=%s retained=%s (%s bytes)\n' \
                "$slot_name" "$slot_type" "$plugin" "$db_name" "$retained_pretty" "$retained_bytes"
        fi
    done <<< "$candidates"

    if [[ "$found_count" -eq 0 ]]; then
        printf '[OK] No inactive replication slots exceed %s MiB threshold.\n' "$threshold_mb"
    fi
}

main "$@"

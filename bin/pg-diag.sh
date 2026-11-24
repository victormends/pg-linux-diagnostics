#!/usr/bin/env bash
set -euo pipefail

# pg-diag.sh - Read-only PostgreSQL diagnostic CLI wrapper.

usage() {
    cat <<'EOF'
Usage: pg-diag.sh [OPTIONS]

Run read-only PostgreSQL diagnostics against PGHOST/PGPORT/PGUSER/PGDATABASE.

Options:
  --check <name>     Diagnostic check to run: all, slots, locks, toast, auth (default: all)
  --format <fmt>     Output format: table, csv, json (default: table)
  -h, --help         Show this help message and exit

Environment:
  PGHOST             PostgreSQL host (default: 127.0.0.1)
  PGPORT             PostgreSQL port (default: 5432)
  PGUSER             PostgreSQL user (default: postgres)
  PGDATABASE         PostgreSQL database (default: postgres)
  PGPASSWORD         Optional password (or configure ~/.pgpass)
EOF
}

die_usage() {
    local msg
    msg="$1"
    printf 'ERROR: %s\n\n' "$msg" >&2
    usage >&2
    exit 2
}

read_sql_without_semicolon() {
    local sql_file
    local raw
    sql_file="$1"
    if [[ ! -f "$sql_file" ]]; then
        printf 'ERROR: Missing SQL file: %s\n' "$sql_file" >&2
        exit 1
    fi
    raw=$(<"$sql_file")
    while [[ "$raw" =~ [[:space:]]$ ]]; do
        raw="${raw%[[:space:]]}"
    done
    raw="${raw%;}"
    printf '%s\n' "$raw"
}

check_to_file() {
    local sql_dir
    local check_name
    sql_dir="$1"
    check_name="$2"
    case "$check_name" in
        slots) printf '%s\n' "${sql_dir}/01_replication_slots_wal.sql" ;;
        locks) printf '%s\n' "${sql_dir}/02_lock_wait_chains.sql" ;;
        toast) printf '%s\n' "${sql_dir}/03_toast_and_table_growth.sql" ;;
        auth)  printf '%s\n' "${sql_dir}/04_auth_and_hba_audit.sql" ;;
        *)
            printf 'ERROR: Unknown check: %s\n' "$check_name" >&2
            exit 2
            ;;
    esac
}

run_single_check() {
    local sql_file
    local format
    local body
    local wrapped
    sql_file="$1"
    format="$2"

    case "$format" in
        table)
            psql -X -v ON_ERROR_STOP=1 -P pager=off -f "$sql_file"
            ;;
        csv)
            psql -X -v ON_ERROR_STOP=1 --csv -f "$sql_file"
            ;;
        json)
            body=$(read_sql_without_semicolon "$sql_file")
            wrapped="SELECT COALESCE(json_agg(t), '[]'::json) FROM (
${body}
) AS t;"
            psql -X -v ON_ERROR_STOP=1 -A -t -q -c "$wrapped"
            ;;
        *)
            die_usage "Unsupported format: ${format}"
            ;;
    esac
}

run_all_json() {
    local sql_dir
    local slots_sql
    local locks_sql
    local toast_sql
    local auth_sql
    local wrapped
    sql_dir="$1"

    slots_sql=$(read_sql_without_semicolon "${sql_dir}/01_replication_slots_wal.sql")
    locks_sql=$(read_sql_without_semicolon "${sql_dir}/02_lock_wait_chains.sql")
    toast_sql=$(read_sql_without_semicolon "${sql_dir}/03_toast_and_table_growth.sql")
    auth_sql=$(read_sql_without_semicolon "${sql_dir}/04_auth_and_hba_audit.sql")

    wrapped="SELECT json_build_object(
  'slots', (SELECT COALESCE(json_agg(t), '[]'::json) FROM (
${slots_sql}
) AS t),
  'locks', (SELECT COALESCE(json_agg(t), '[]'::json) FROM (
${locks_sql}
) AS t),
  'toast', (SELECT COALESCE(json_agg(t), '[]'::json) FROM (
${toast_sql}
) AS t),
  'auth', (SELECT COALESCE(json_agg(t), '[]'::json) FROM (
${auth_sql}
) AS t)
);"
    psql -X -v ON_ERROR_STOP=1 -A -t -q -c "$wrapped"
}

main() {
    local check="all"
    local format="table"
    local script_dir
    local root_dir
    local sql_dir
    local sql_file
    local item
    local -a checks=("slots" "locks" "toast" "auth")

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check)
                if [[ $# -lt 2 || -z "$2" ]]; then
                    die_usage "--check requires a value"
                fi
                check="$2"
                shift 2
                ;;
            --check=*)
                check="${1#*=}"
                if [[ -z "$check" ]]; then
                    die_usage "--check requires a value"
                fi
                shift
                ;;
            --format)
                if [[ $# -lt 2 || -z "$2" ]]; then
                    die_usage "--format requires a value"
                fi
                format="$2"
                shift 2
                ;;
            --format=*)
                format="${1#*=}"
                if [[ -z "$format" ]]; then
                    die_usage "--format requires a value"
                fi
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

    case "$check" in
        all|slots|locks|toast|auth) ;;
        *) die_usage "Invalid --check value '${check}'. Expected: all, slots, locks, toast, auth." ;;
    esac

    case "$format" in
        table|csv|json) ;;
        *) die_usage "Invalid --format value '${format}'. Expected: table, csv, json." ;;
    esac

    if ! command -v psql >/dev/null 2>&1; then
        printf 'ERROR: psql binary not found in PATH.\n' >&2
        exit 1
    fi

    export PGHOST="${PGHOST:-127.0.0.1}"
    export PGPORT="${PGPORT:-5432}"
    export PGUSER="${PGUSER:-postgres}"
    export PGDATABASE="${PGDATABASE:-postgres}"

    if [[ -n "${PGOPTIONS:-}" ]]; then
        export PGOPTIONS="${PGOPTIONS} -c default_transaction_read_only=on"
    else
        export PGOPTIONS="-c default_transaction_read_only=on"
    fi

    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    root_dir=$(cd "${script_dir}/.." && pwd)
    sql_dir="${root_dir}/sql"

    if [[ "$check" == "all" ]]; then
        if [[ "$format" == "json" ]]; then
            run_all_json "$sql_dir"
        else
            for item in "${checks[@]}"; do
                sql_file=$(check_to_file "$sql_dir" "$item")
                if [[ "$format" == "table" ]]; then
                    printf '=== Check: %s ===\n' "$item"
                else
                    printf '# check: %s\n' "$item"
                fi
                run_single_check "$sql_file" "$format"
            done
        fi
    else
        sql_file=$(check_to_file "$sql_dir" "$check")
        run_single_check "$sql_file" "$format"
    fi
}

main "$@"

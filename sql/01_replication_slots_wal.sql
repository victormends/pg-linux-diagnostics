-- Check 01: Replication slots and retained WAL inspection.
-- Identifies inactive or lagging slots retaining WAL segments and compares
-- retained bytes against max_slot_wal_keep_size.
SELECT
    s.slot_name,
    s.plugin,
    s.slot_type,
    s.database,
    s.active,
    s.temporary,
    s.active_pid,
    r.state AS replication_state,
    r.client_addr::text AS client_addr,
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
    ) AS retained_wal_pretty,
    current_setting('max_slot_wal_keep_size') AS max_slot_wal_keep_size
FROM pg_catalog.pg_replication_slots AS s
LEFT JOIN pg_catalog.pg_stat_replication AS r
    ON s.active_pid = r.pid
ORDER BY s.active ASC, retained_wal_bytes DESC;

-- Check 02: Lock wait chains and blocking PID attribution.
-- Adapted from the PostgreSQL Wiki "Lock_Monitoring" pattern using
-- pg_catalog.pg_blocking_pids() for direct blocker-to-blocked mapping.
SELECT
    blocker.pid AS blocker_pid,
    blocker.usename AS blocker_user,
    blocker.state AS blocker_state,
    blocked.pid AS blocked_pid,
    blocked.usename AS blocked_user,
    COALESCE(
        EXTRACT(EPOCH FROM (clock_timestamp() - blocked.state_change)),
        0
    )::numeric(12, 2) AS wait_seconds,
    blocked.wait_event AS wait_event,
    left(regexp_replace(COALESCE(blocker.query, ''), '\s+', ' ', 'g'), 120) AS blocker_query,
    left(regexp_replace(COALESCE(blocked.query, ''), '\s+', ' ', 'g'), 120) AS blocked_query
FROM pg_catalog.pg_stat_activity AS blocked
JOIN LATERAL unnest(pg_blocking_pids(blocked.pid)) AS blocker_pid
    ON true
JOIN pg_catalog.pg_stat_activity AS blocker
    ON blocker.pid = blocker_pid
WHERE blocked.pid <> pg_backend_pid()
ORDER BY wait_seconds DESC;

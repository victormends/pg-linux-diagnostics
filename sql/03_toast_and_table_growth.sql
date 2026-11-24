-- Check 03: User table storage growth breakdown (heap + TOAST + index).
-- Note: This measures actual physical storage growth across heap, TOAST, and
-- index forks (pg_relation_size / pg_total_relation_size), which is distinct
-- from dead-tuple bloat (reclaimable free space inside existing pages).
SELECT
    n.nspname AS schema_name,
    c.relname AS table_name,
    c.relkind AS relation_kind,
    pg_relation_size(c.oid)::bigint AS table_heap_bytes,
    pg_size_pretty(pg_relation_size(c.oid)) AS table_heap_pretty,
    COALESCE(pg_total_relation_size(c.reltoastrelid), 0)::bigint AS toast_bytes,
    pg_size_pretty(COALESCE(pg_total_relation_size(c.reltoastrelid), 0)) AS toast_pretty,
    pg_indexes_size(c.oid)::bigint AS index_bytes,
    pg_size_pretty(pg_indexes_size(c.oid)) AS index_pretty,
    pg_total_relation_size(c.oid)::bigint AS total_bytes,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS total_pretty
FROM pg_catalog.pg_class AS c
JOIN pg_catalog.pg_namespace AS n
    ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
  AND n.nspname NOT LIKE 'pg_temp_%'
  AND n.nspname NOT LIKE 'pg_toast_temp_%'
ORDER BY total_bytes DESC
LIMIT 30;

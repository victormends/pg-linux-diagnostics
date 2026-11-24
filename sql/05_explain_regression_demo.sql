-- Demo 05: Deterministic EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) regression demo.
-- Populates 100,000 synthetic rows in diag_events and compares sequential scan
-- cost and buffer reads before and after creating a composite (tenant_id, created_at) index.

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

-- Disable parallel gather for deterministic single-worker Seq Scan baseline.
SET max_parallel_workers_per_gather = 0;

-- Baseline plan BEFORE composite index creation:
EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
SELECT id, tenant_id, created_at
FROM diag_events
WHERE tenant_id = 42
  AND created_at >= TIMESTAMPTZ '2026-01-06 00:00:00+00';

CREATE INDEX idx_diag_events_tenant_created
    ON diag_events (tenant_id, created_at);

ANALYZE diag_events;

-- Optimized plan AFTER composite index creation:
EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
SELECT id, tenant_id, created_at
FROM diag_events
WHERE tenant_id = 42
  AND created_at >= TIMESTAMPTZ '2026-01-06 00:00:00+00';

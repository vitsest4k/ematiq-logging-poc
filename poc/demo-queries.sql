-- ============================================================
-- Ematiq Logging PoC — Demo Queries
-- Run at: http://localhost:8123/play
-- ============================================================

-- ── 1. All sources ingesting ─────────────────────────────────
-- Shows env=local (k8s) + env=external (risk-server via aggregator)
SELECT env, service, count() AS logs, max(timestamp) AS last_seen
FROM default.logs
GROUP BY env, service
ORDER BY env, logs DESC;


-- ── 2. Live log volume per minute ────────────────────────────
-- Confirms the pipeline is actively flowing
SELECT toStartOfMinute(timestamp) AS minute, service, count() AS logs
FROM default.logs
WHERE timestamp > now() - INTERVAL 5 MINUTE
GROUP BY minute, service
ORDER BY minute DESC, logs DESC;


-- ── 3. p99 order execution latency by symbol ─────────────────
-- Structured JSON fields extracted at query time — no schema migration needed
SELECT
    fields['symbol']                                          AS symbol,
    quantile(0.50)(toFloat64OrZero(fields['latency_us']))    AS p50_us,
    quantile(0.99)(toFloat64OrZero(fields['latency_us']))    AS p99_us,
    count()                                                   AS orders
FROM default.logs
WHERE service = 'order-executor'
GROUP BY symbol
ORDER BY p99_us DESC;


-- ── 4. Risk check failure rate by symbol ─────────────────────
SELECT
    fields['symbol']                                                       AS symbol,
    countIf(fields['risk_check'] = 'failed')                               AS failures,
    count()                                                                AS total,
    round(countIf(fields['risk_check'] = 'failed') / count() * 100, 1)    AS failure_pct
FROM default.logs
WHERE service = 'order-executor'
GROUP BY symbol
ORDER BY failure_pct DESC;


-- ── 5. Portfolio risk breaches (external source) ─────────────
-- Logs shipped from outside the cluster via Vector Aggregator
SELECT
    fields['portfolio']                               AS portfolio,
    countIf(fields['action'] = 'halt')                AS halts,
    countIf(fields['action'] = 'allow')               AS allowed,
    max(toFloat64OrZero(fields['exposure_usd']))       AS max_exposure_usd
FROM default.logs
WHERE service = 'risk-server'
GROUP BY portfolio
ORDER BY halts DESC;


-- ── 6. Grep — errors across every service ────────────────────
-- Full-text search across the entire fleet in one query
SELECT timestamp, env, service, level, message
FROM default.logs
WHERE level = 'ERROR'
ORDER BY timestamp DESC
LIMIT 20;


-- ── 7. Hot vs cold storage (tiered MinIO) ────────────────────
-- Data older than 1 min auto-moves to s3_cold (MinIO)
-- Shows both 'default' (hot) and 's3_cold' (cold) disks populated
SELECT
    disk_name,
    count()                                   AS parts,
    sum(rows)                                 AS rows,
    formatReadableSize(sum(bytes_on_disk))    AS size_on_disk
FROM system.parts
WHERE table = 'logs' AND database = 'default' AND active
GROUP BY disk_name;

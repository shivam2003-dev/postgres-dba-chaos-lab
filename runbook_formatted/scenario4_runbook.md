# Scenario 4 Runbook

## Analytics Workload, Diagnosis, and Recovery

---

## Start the Analytical Workload

```bash
sudo -u postgres bash /data/workshop/analytics/analytics.sh
```

---

## Diagnosis Steps

### Stage 1: Check PostgreSQL Logs

Read the most recent log entries.

```bash
sudo tail -60 /data/analytics/log
```

### Stage 2: Check System Logs and Cluster Status

#### 2.1 Check Kernel and System Log Activity

```bash
sudo cat /var/log/syslog | grep 'postgres'
```

#### 2.2 Check PostgreSQL Analytics Cluster Status

```bash
sudo systemctl status postgresql@18-analytics.service
```

#### 2.3 If the Cluster Is Deactivating, Stop It Immediately

```bash
/usr/bin/pg_ctlcluster --skip-systemctl-redirect -m immediate 18-analytics stop
```

#### 2.4 Start the Cluster Cleanly for Diagnosis

```bash
sudo systemctl start postgresql@18-analytics.service
```

---

## Stage 3: Check Table Bloat

### 3.1 Review Dead Tuple Ratios for User Tables

```sql
SELECT
    relname,
    n_live_tup,
    n_dead_tup,
    round(n_dead_tup::numeric / GREATEST(n_live_tup, 1) * 100, 2) AS dead_pct,
    pg_size_pretty(pg_relation_size(relid)) AS table_size,
    last_vacuum,
    last_autovacuum,
    last_analyze,
    last_autoanalyze
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC;
```

**Expected result:** statistics tables may appear frozen and not show updated tuple counts.

### 3.2 Precise Bloat Measurement for All User Tables

```sql
SELECT
    n.nspname AS schemaname,
    c.relname,
    (pgstattuple(c.oid)).tuple_count AS live_tuples,
    (pgstattuple(c.oid)).dead_tuple_count AS dead_tuples,
    (pgstattuple(c.oid)).dead_tuple_percent,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS table_size,
    s.last_vacuum,
    s.last_autovacuum
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname !~ '^pg_toast'
ORDER BY dead_tuples DESC;
```

### 3.3 Precise Bloat Measurement for `payment_transactions`

```sql
SELECT
    table_len,
    pg_size_pretty(table_len::bigint) AS table_size,
    tuple_count AS live_tuples,
    dead_tuple_count AS dead_tuples,
    round(dead_tuple_percent::numeric, 2) AS dead_pct,
    pg_size_pretty(dead_tuple_len::bigint) AS dead_space,
    pg_size_pretty(free_space::bigint) AS free_space
FROM pgstattuple('payment_transactions');
```

### 3.4 Precise Bloat Measurement for `orders`

```sql
SELECT
    table_len,
    pg_size_pretty(table_len::bigint) AS table_size,
    tuple_count AS live_tuples,
    dead_tuple_count AS dead_tuples,
    round(dead_tuple_percent::numeric, 2) AS dead_pct,
    pg_size_pretty(dead_tuple_len::bigint) AS dead_space,
    pg_size_pretty(free_space::bigint) AS free_space
FROM pgstattuple('orders');
```

---

## Stage 4: Check Cluster-Level Autovacuum Settings

### 4.1 Check Global Autovacuum Settings

```sql
SELECT name, setting, unit, source
FROM pg_settings
WHERE name IN (
    'autovacuum',
    'autovacuum_max_workers',
    'autovacuum_vacuum_cost_delay',
    'autovacuum_vacuum_cost_limit'
)
ORDER BY name;
```

### 4.2 Check Table-Level Overrides on Affected Tables

```sql
SELECT c.relname, c.reloptions
FROM pg_class c
WHERE c.relname IN ('payment_transactions', 'orders');
```

**Expected result:** `{autovacuum_enabled=false}` on both tables.

### 4.3 Review Key Memory and Connection Settings

```sql
show work_mem;
show shared_buffers;
show max_connections;
```

---

## Stage 5: Validate Parameters

### 5.1 Validate Runtime Values, Sources, and Restart Requirements

```sql
SELECT
    name,
    setting,
    unit,
    source,
    pending_restart
FROM pg_settings
WHERE name IN (
    'autovacuum',
    'autovacuum_max_workers',
    'autovacuum_naptime',
    'autovacuum_vacuum_scale_factor',
    'autovacuum_analyze_scale_factor',
    'autovacuum_vacuum_threshold',
    'autovacuum_analyze_threshold',
    'autovacuum_vacuum_cost_delay',
    'autovacuum_vacuum_cost_limit',
    'autovacuum_work_mem',
    'work_mem',
    'shared_buffers',
    'max_connections'
)
ORDER BY name;
```

### 5.2 Confirm Value Sources

```sql
SELECT
    name,
    setting,
    source,
    sourcefile,
    sourceline
FROM pg_settings
WHERE name IN (
    'work_mem',
    'shared_buffers',
    'max_connections',
    'autovacuum',
    'autovacuum_max_workers'
)
ORDER BY name;
```

> `pending_restart = 't'` means the value is set but not active until PostgreSQL is restarted.

### 5.3 Check for Active Vacuum Workers

```sql
SELECT
    pid,
    datname,
    relid::regclass AS table_name,
    phase,
    heap_blks_total,
    heap_blks_scanned,
    heap_blks_vacuumed
FROM pg_stat_progress_vacuum;
```

**Expected result:** empty result set if no vacuum is currently running.

---

## Phase A: Immediate Stabilization

### 6.1 Apply Recovery Settings

```sql
ALTER SYSTEM SET work_mem = '32MB';
ALTER SYSTEM SET autovacuum_max_workers = 3;
ALTER SYSTEM SET autovacuum_vacuum_cost_delay = '2ms';
ALTER SYSTEM SET max_connections = '25';
ALTER TABLE payment_transactions RESET (autovacuum_enabled);
ALTER TABLE orders RESET (autovacuum_enabled);

SELECT pg_reload_conf();
```

### 6.2 Verify Global Settings

```sql
SHOW autovacuum_max_workers;
SHOW work_mem;
SHOW max_connections;
SHOW autovacuum;
SHOW autovacuum_vacuum_cost_delay;
```

**Expected values:**
- `autovacuum_max_workers = 3`
- `work_mem = 32MB`
- `autovacuum = ON`
- `autovacuum_vacuum_cost_delay = 2ms`

### 6.3 Verify Table-Level Overrides Are Removed

```sql
SELECT relname, reloptions
FROM pg_class
WHERE relname IN ('payment_transactions', 'orders');
```

**Expected result:** `reloptions` should be `NULL` for both tables.

### 6.4 Run Vacuum

```sql
VACUUM payment_transactions;
VACUUM orders;
VACUUM;
```

> `VACUUM` without `FULL` does not lock the table for writes.

---

## Stage 6: Final Verification

Confirm dead tuples are reclaimed.

```sql
SELECT
    n.nspname AS schemaname,
    c.relname,
    (pgstattuple(c.oid)).tuple_count AS live_tuples,
    (pgstattuple(c.oid)).dead_tuple_count AS dead_tuples,
    (pgstattuple(c.oid)).dead_tuple_percent,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS table_size,
    s.last_vacuum,
    s.last_autovacuum
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname !~ '^pg_toast'
ORDER BY dead_tuples DESC;
```

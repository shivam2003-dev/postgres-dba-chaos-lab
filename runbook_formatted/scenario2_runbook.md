# Scenario 2 Runbook

## Replica Lag Spike, WAL Flood, and Disk Pressure

---

## Phase 1: First Alert

### 1.1 Check Replication Status

```bash
psql -c "SELECT client_addr, application_name, state, sent_lsn, write_lsn, replay_lag,
pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS lag_bytes
FROM pg_stat_replication;"
```

### 1.2 Inspect Replication Slots

```bash
psql -c "SELECT slot_name, slot_type, active, restart_lsn,
pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal,
wal_status
FROM pg_replication_slots
ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC;"
```

### 1.3 Verify Disk Pressure

```bash
df -h /data
du -sh /data/primary/pg_wal/
```

---

## Phase 2: Escalation - WAL Flood and Disk Pressure

### 2.1 Check WAL Accumulation by Slot

```bash
psql -c "SELECT slot_name, wal_status,
pg_size_pretty(pg_wal_lsn_diff(
pg_current_wal_lsn(), restart_lsn))
AS retained
FROM pg_replication_slots;"
```

### 2.2 Watch WAL Accumulation Live

```bash
watch -n 1 'psql -c "SELECT slot_name, wal_status,
pg_size_pretty(pg_wal_lsn_diff(
pg_current_wal_lsn(), restart_lsn))
AS retained
FROM pg_replication_slots;"'
```

### 2.3 Verify Archive Failures

```bash
psql -c "SELECT failed_count, last_failed_time
FROM pg_stat_archiver;"
```

### 2.4 Check Disk and Logs

```bash
df -h /data/primary
tail -f /var/log/postgresql/postgresql-18-primary.log
```

---

## Phase 3: Crisis - PITR Broken and Disk Usage at 92%

### 3.1 Stop Workload or Throttle I/O

Option 1:

```bash
docker stop pg-workload
```

Option 2:

```bash
psql -c "ALTER SYSTEM SET checkpoint_completion_target = 0.9; SELECT pg_reload_conf();"
```

### 3.2 Verify Slot Is Inactive

```bash
psql -c "SELECT slot_name, active, active_pid
FROM pg_replication_slots
WHERE slot_name='analytics_slot';"
```

### 3.3 Apply the Fix

Option 1: Drop the orphaned slot.

```bash
psql -c "SELECT pg_drop_replication_slot('analytics_slot');"
```

Option 2: Re-enable the subscription.

```bash
psql -p 5435 -c "alter subscription analytics_sub enable;"
```

### 3.4 Watch WAL Accumulation Live Again

```bash
watch -n 1 'psql -c "SELECT slot_name, wal_status,
pg_size_pretty(pg_wal_lsn_diff(
pg_current_wal_lsn(), restart_lsn))
AS retained
FROM pg_replication_slots;"'
```

### 3.5 Reclaim Space and Re-Baseline

```sql
CHECKPOINT;
```

```bash
pg_basebackup -D /tmp/fresh_backup ...
```

---

## Phase 4: Stabilization, Verification, and Prevention

### 4.1 Set a Safety Valve

```sql
ALTER SYSTEM SET max_slot_wal_keep_size = '5GB';
SELECT pg_reload_conf();
```

### 4.2 Resume Operations

```bash
docker start pg-workload
```

---

## Monitoring Queries

### Alert: Inactive Replication Slot with WAL Greater Than 1 GB

```sql
SELECT
    slot_name,
    slot_type,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots
WHERE NOT active
  AND pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) > 1073741824;
```

### Alert: WAL Archive Falling Behind

```sql
SELECT
    (last_failed_time > last_archived_time) AS archive_failing,
    failed_count,
    now() - last_archived_time AS time_since_last_archive
FROM pg_stat_archiver;
```

### Alert: `pg_wal` Directory Growing Beyond Threshold

```bash
WAL_SIZE=$(du -sm /var/lib/postgresql/data/pg_wal/ | cut -f1)
if [ $WAL_SIZE -gt 5120 ]; then
  echo 'CRITICAL: pg_wal exceeds 5GB ($WAL_SIZE MB)'
fi
```

---

## Quick Reference

### List Replication Slots

```sql
SELECT * FROM pg_replication_slots;
```

### Check WAL Retained by a Slot

```sql
pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn))
```

### Drop an Orphaned Slot

```sql
SELECT pg_drop_replication_slot('slot_name');
```

### Check Replication Lag

```sql
SELECT replay_lag FROM pg_stat_replication;
```

### Check Archiver Status

```sql
SELECT * FROM pg_stat_archiver;
```

### Force a WAL Switch

```sql
SELECT pg_switch_wal();
```

### Force a Checkpoint

```sql
CHECKPOINT;
```

### Set Slot WAL Limit

```sql
ALTER SYSTEM SET max_slot_wal_keep_size = '5GB';
```

### Check WAL Directory Size

```bash
du -sh $PGDATA/pg_wal/
```

### Count WAL Segments

```bash
ls $PGDATA/pg_wal/ | wc -l
```

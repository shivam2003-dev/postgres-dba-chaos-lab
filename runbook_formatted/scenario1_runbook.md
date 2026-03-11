# Scenario 1 Runbook

## PostgreSQL 18.3 Corruption Investigation and Recovery

**Cluster:** Nagulan  
**Data Directory:** `/data/primary`  
**Port:** `5432`  
**Database:** `postgres`  
**Schema:** `public`  
**Updated:** `2026-03`

---

## How to Use This Runbook

Run sections in order from top to bottom during an active investigation.

Each query block includes:
- what it does,
- why it matters, and
- when to use it.

## Prerequisites

```sql
CREATE EXTENSION IF NOT EXISTS pageinspect;
CREATE EXTENSION IF NOT EXISTS amcheck;
```

```bash
psql < corruption_scanner_v4.sql
psql < row_level_diagnosis.sql
```

---

## 1. Reproduce or Confirm Corruption

### 1.1 Simulate Corruption (Lab Only)

Runs the Python corruption simulator against specific rows in `payment_transactions`.

- Stops PostgreSQL
- Overwrites column data bytes inside the heap file
- Recalculates the PostgreSQL 18 page checksum
- Restarts PostgreSQL

> Use only in a lab environment. This permanently corrupts the named rows.

```bash
python3 03b_corrupt_records.py \
    --db postgres \
    --table payment_transactions \
    --pk txn_id \
    --pk-values 101 205 398 512 777
```

### 1.2 Spot-Check Known Corrupt Primary Keys

Attempts a direct `SELECT` of the suspected corrupt rows.

> If rows are cached in `shared_buffers`, this may return stale pre-corruption data. Restart PostgreSQL first for a definitive check.

```sql
SELECT *
FROM payment_transactions
WHERE txn_id IN (101, 205, 398, 512, 777);
```

### 1.3 Restart PostgreSQL to Flush Buffer Cache

Restart before running definitive scans if corruption was introduced after the data was cached.

```bash
sudo systemctl status postgresql@18-primary.service
```

---

## 2. Identify the Corrupted Table

### 2.1 Check PostgreSQL Error Logs

Look for errors such as:

- `invalid page in block 2 of relation base/5/16482`

The two important values are:
- database OID: `5`
- relfilenode: `16482`

```bash
grep -C5 "ERROR" /var/log/postgresql/postgresql-18-primary.log
```

### 2.2 Translate Database OID to Database Name

Replace `5` with the OID from the log.

```sql
SELECT datname
FROM pg_database
WHERE oid = '5';
```

### 2.3 Translate Relfilenode to Schema-Qualified Table Name

Replace `16482` with the relfilenode from the log.

```sql
SELECT
    c.relname AS table_name,
    n.nspname AS schema_name,
    c.relkind AS relation_type
FROM pg_class c
JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE pg_relation_filenode(c.oid) = 16482;
```

### 2.4 Confirm the Data Directory

```sql
SHOW data_directory;
```

---

## 3. Take a Pre-Investigation Backup

### 3.1 Start an Online Backup Window

```sql
SELECT pg_backup_start('pre_investigation_backup', false);
```

### 3.2 Copy the Data Directory with `rsync`

Run this in a separate terminal after starting the backup window.

```bash
rsync -ar /data/primary/ /data/backup/
```

### 3.3 End the Online Backup Window

Run only after `rsync` completes successfully.

```sql
SELECT * FROM pg_backup_stop();
```

### 3.4 Alternative: Full Backup with `pg_basebackup`

```bash
/usr/lib/postgresql/18/bin/pg_basebackup -h localhost -U postgres -D /data/backup -Fp -Xs -P
```

---

## 4. Verify Checksums

### 4.1 Confirm Data Checksums Are Enabled

```sql
SHOW data_checksums;
```

Alternative:

```sql
SELECT name, setting
FROM pg_settings
WHERE name = 'data_checksums';
```

### 4.2 Run Cluster-Wide Checksum Verification

> PostgreSQL must be stopped before running `pg_checksums`.

```bash
sudo systemctl stop postgresql@18-primary.service
/usr/lib/postgresql/18/bin/pg_checksums --check -D /data/primary
```

---

## 5. Run the Two-Pass Corruption Scanner

### 5.1 Scan All Tables for Corruption

```sql
CALL scan_all_tables_for_corruption(p_verify_heapam => TRUE);
```

### 5.2 View Latest Scan Results

```sql
SELECT
    block_num,
    ctid_val,
    detection_pass,
    error_type,
    error_detail
FROM v_corruption_latest
WHERE table_name = 'payment_transactions'
ORDER BY block_num, detection_pass;
```

---

## 6. Inspect Raw Page Headers

### 6.1 Inspect a Raw 8 KB Page Header

Replace `2` with the actual block number.

```sql
SELECT *
FROM page_header(get_raw_page('payment_transactions', 2));
```

---

## 7. Check Index Integrity with `amcheck`

### 7.1 Cross-Reference Index Entries Against the Heap

```sql
SELECT bt_index_parent_check('idx_payment_status', heapallindexed => true);
```

### 7.2 Batch Index Check Across Multiple Tables

```sql
SELECT
    n.nspname AS schema_name,
    c.relname AS table_name,
    i.relname AS index_name,
    bt_index_parent_check(i.oid, heapallindexed => true) AS check_result
FROM pg_index x
JOIN pg_class c ON c.oid = x.indrelid
JOIN pg_class i ON i.oid = x.indexrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname IN ('payment_transactions');
```

---

## 8. Perform Row-Level Diagnosis

### 8.1 Diagnose Rows in a Single Table

```sql
CALL diagnose_table_rows('payment_transactions', 'txn_id');
```

### 8.2 List Corrupt Rows with Details

```sql
SELECT
    pk_value,
    ctid_val,
    block_num,
    item_index,
    error_type,
    error_detail,
    raw_xmin,
    tuple_len,
    diagnosed_at
FROM row_corruption_diagnosis
WHERE table_name = 'payment_transactions'
  AND is_corrupted = TRUE
ORDER BY block_num, item_index;
```

### 8.3 View Diagnosis Summary

```sql
SELECT *
FROM v_row_diagnosis_summary
ORDER BY corrupt_rows DESC;
```

---

## 9. Check Replication Status

### 9.1 Review Streaming Replication Lag and Replica Health

```sql
SELECT
    application_name,
    client_addr,
    state,
    sync_state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn,
    write_lag,
    flush_lag,
    replay_lag
FROM pg_stat_replication;
```

---

## 10. Surgical Block Repair from a Replica

### 10.1 Copy One 8 KB Block with `dd`

> PostgreSQL must be stopped on the primary before running this command.

```bash
sudo systemctl stop postgresql@18-primary.service

dd if=/data/replica2/base/5/16482 \
   of=/data/primary/base/5/16482 \
   bs=8192 count=1 skip=2 seek=2 conv=notrunc

sudo systemctl start postgresql@18-primary.service
```

- `skip=2` reads block `2` from the replica
- `seek=2` writes block `2` to the primary

---

## 11. Full Table Recovery from a Replica

### 11.1 Dump the Healthy Table from the Replica

```bash
/usr/lib/postgresql/18/bin/pg_dump -U postgres -d postgres -p 5434 -t payment_transactions > /data/backup/transactions_backup.sql
```

### 11.2 Drop or Rename the Corrupt Table Before Restore

```sql
DROP TABLE public.payment_transactions;
```

### 11.3 Restore the Healthy Table

```bash
psql -U postgres -d postgres -p 5432 -f /data/backup/transactions_backup.sql
```

### 11.4 Rebuild Indexes and Refresh Statistics

```sql
REINDEX TABLE public.payment_transactions;
ANALYZE public.payment_transactions;
```

### 11.5 Validate Row Count

```sql
SELECT count(*) FROM payment_transactions;
```

### 11.6 Validate Indexes Against Heap Tuples

```sql
SELECT
    c.relname AS index_name,
    bt_index_parent_check(c.oid, heapallindexed => true) AS result
FROM pg_class c
JOIN pg_index i ON c.oid = i.indexrelid
WHERE i.indrelid = 'payment_transactions'::regclass;
```

### 11.7 Final `pg_dump` Sanity Check

```bash
pg_dump -U postgres -p 5432 -d postgres --schema=public -f /dev/null 2>&1 | grep -i error
```

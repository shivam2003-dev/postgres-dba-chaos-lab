
# PG Training Notes

## Access
- pgAdmin URL: http://3.111.218.76:8080/browser/
- pgAdmin user: sdb@iitmpravartak.net
- pgAdmin password: Adm!n@123

## System Credentials
- postgres password: SecretPass
- ubuntu password: PgConf#2026!

## Task
Identify the databases and tables in each database.

## Validate PostgreSQL Clusters

### 1) Check all running PostgreSQL services
```bash
systemctl list-units --type=service | grep -i postgresql
```

### 2) Check one cluster status
```bash
sudo systemctl status postgresql@18-<cluster-name>.service
```

Example:
```bash
sudo systemctl status postgresql@18-primary.service
```

### 3) Check all known clusters quickly
```bash
for c in analytics logical primary replica1 replica2; do
	echo "=== $c ==="
	systemctl is-active "postgresql@18-$c.service"
done
```

## Find DataDir / ConfigDir / LogDir

### 1) First find cluster ports
```bash
pg_lsclusters
```

### 2) For a given port, print key directories/files
```bash
sudo -u postgres psql -p <PORT> -Atc "show data_directory; show config_file; show hba_file; show log_directory;"
```

Example:
```bash
sudo -u postgres psql -p 5432 -Atc "show data_directory; show config_file; show hba_file; show log_directory;"
```

## Connect with psql

```bash
sudo -u postgres psql -p <PORT>
```

Connect directly to a database:
```bash
sudo -u postgres psql -p <PORT> -d <DB_NAME>
```

## Identify Databases and Tables

Inside `psql`:
```sql
\l
\c <DB_NAME>
\dt
\dt *.*
```



---
Incident #1 :  The day starts with a strange error 
---

the problem is the intermittent api failure 

status : 500
- the api is failing intermittently with 500 error code
- the error is not consistent and happens randomlygo to the log file 





## 🛠️ Tools You'll Need for Corruption Investigation & Recovery

### PostgreSQL Extensions (Install First)
```sql
CREATE EXTENSION IF NOT EXISTS pageinspect;
CREATE EXTENSION IF NOT EXISTS amcheck;
```
| Tool | Purpose | When to Use |
|------|---------|------------|
| **pageinspect** | Read raw 8KB page headers, inspect tuple structure at byte level | Diagnosing unreadable blocks, analyzing page corruption |
| **amcheck** | Verify index/heap consistency, detect logical corruption (HOT chains, TOAST pointers) | Deep corruption verification before recovery |

### PostgreSQL Scanner Scripts (Install Once)
```bash
psql < corruption_scanner_v4.sql       # Installs scanning stored procedures
psql < row_level_diagnosis.sql         # Installs row-level probe procedures
```
| Script | Provides | Use Case |
|--------|----------|----------|
| **corruption_scanner_v4.sql** | Two-pass scanner (`scan_all_tables_for_corruption()`) | Find all corrupt tuples across entire database |
| **row_level_diagnosis.sql** | Row-by-row probe (`diagnose_table_rows()`) + summary views | List corrupt rows with PKs, error types, raw headers |

### CLI Tools (Already Installed on Server)
| Tool | Location | Purpose | Example |
|------|----------|---------|---------|
| **psql** | `/usr/bin/psql` | Connect to database, run queries | `psql -U postgres -p 5432 -d postgres` |
| **pg_dump** | `/usr/lib/postgresql/18/bin/pg_dump` | Export table/database to SQL | `pg_dump -U postgres -p 5434 -t payment_transactions` |
| **pg_basebackup** | `/usr/lib/postgresql/18/bin/pg_basebackup` | Full binary backup from primary | `pg_basebackup -h localhost -U postgres -D /data/backup` |
| **pg_checksums** | `/usr/lib/postgresql/18/bin/pg_checksums` | Verify page checksums (DB must be stopped) | `pg_checksums --check -D /data/primary` |
| **pg_lsclusters** | `/usr/bin/pg_lsclusters` | List all clusters, ports, versions, status | `pg_lsclusters` |

### System Tools (Already Available)
| Tool | Purpose | Example |
|------|---------|---------|
| **systemctl** | Manage PostgreSQL services (start/stop/status) | `sudo systemctl status postgresql@18-primary.service` |
| **dd** | Copy single 8KB blocks from replica → primary | `dd if=/data/replica/base/5/16482 of=/data/primary/base/5/16482 bs=8192` |
| **rsync** | Bulk copy data directory with permissions preserved | `rsync -ar /data/primary/ /data/backup/` |
| **grep** | Search error logs for corruption messages | `grep -C5 "ERROR" /var/log/postgresql/postgresql-18-primary.log` |

### Python Lab Tools (For Corruption Simulation Only)
| Script | Purpose | Use Case | Warning |
|--------|---------|----------|---------|
| **03b_corrupt_records.py** | Simulate corruption by overwriting heap bytes | Lab training only | ⛔ **NEVER in production** |

### Key Queries to Remember
| Query | Purpose | Output |
|-------|---------|--------|
| `SHOW data_directory;` | Get PGDATA location for file ops | `/data/primary` |
| `SELECT datname FROM pg_database WHERE oid = '5';` | Map OID → database name | `postgres` |
| `SELECT pg_relation_filenode(c.oid) FROM pg_class c WHERE c.relname = 'table_name';` | Map relfilenode → table | `16482` |
| `SELECT * FROM pg_stat_replication;` | Check replica lag & LSN sync | Lag times, sync state |
| `CALL scan_all_tables_for_corruption(p_verify_heapam => TRUE);` | Two-pass scan all tables | Populates corruption_scan_results |
| `SELECT * FROM v_corruption_latest WHERE table_name = 'payment_transactions';` | View corrupt tuples found | Block number, ctid, error type |

---

## 🔍 PostgreSQL System Catalog & Information Schema (Diagnosis Foundation)

### System Catalog (`pg_*` tables)
Used to identify which database, table, and file numbers correspond to error messages.

| System Catalog | Purpose | Diagnostic Use |
|-------|---------|---------|
| **pg_database** | Lists all databases with OID | Map error `base/<OID>` → database name |
| **pg_class** | Lists tables, indexes, and relations | Map relfilenode → table name + schema |
| **pg_namespace** | Lists schemas (public, pg_catalog, etc) | Qualify table names with schema |
| **pg_attribute** | Lists all columns per table with type info | Identify data types in corrupted columns |
| **pg_index** | Lists all indexes with relfilenode | Cross-check index integrity with heap |
| **pg_stat_replication** | Replication lag & LSN positions | Measure replica freshness for recovery |

### Example: Translate Error OID to Table Name
```sql
-- Step 1: Error in log says "base/5/16482" — find database OID=5
SELECT datname FROM pg_database WHERE oid = '5';
-- Result: postgres

-- Step 2: Find table with relfilenode 16482 in that database
SELECT c.relname AS table_name, n.nspname AS schema_name 
FROM pg_class c 
JOIN pg_namespace n ON c.relnamespace = n.oid 
WHERE pg_relation_filenode(c.oid) = 16482;
-- Result: payment_transactions | public
```

### Information Schema (`information_schema.*`)
Standard SQL views wrapping pg_* catalog for portability.

| Schema View | Maps To | Use Case |
|-----|-----|-----|
| **information_schema.tables** | pg_class | List all user tables with creation date |
| **information_schema.columns** | pg_attribute | Get column names, types, null constraints |
| **information_schema.schemata** | pg_namespace | List schemas |

```sql
SELECT table_schema, table_name FROM information_schema.tables 
WHERE table_schema = 'public';
```

---

---

## ✅ Why Data Checksums MUST Be Enabled in Production

### What Are Data Checksums?
Each 8KB page in PostgreSQL gets a **16-bit checksum** computed using Fletcher-16 algorithm and stored in the page header. When PostgreSQL reads a page from disk, it recalculates the checksum and compares it to the stored value.

### Why Enable in Production?

| Problem | Without Checksums | With Checksums |
|---------|-------------------|-----------------|
| **Silent Corruption** | ❌ Corruption goes undetected; data is served silently wrong to applications | ✅ Corruption detected at page read time; clear error in log |
| **Root cause clarity** | ❌ Bug manifests in application layer; impossible to prove storage fault | ✅ PostgreSQL clearly states "checksum verification failed" — proves storage/OS bug |
| **Recovery window** | ❌ Weeks/months of corrupted data in backups; unrecoverable | ✅ Detected immediately; backup still clean, can restore quickly |
| **Compliance** | ❌ Cannot prove data integrity for audit/legal | ✅ Checksums prove data was not corrupted in-database |
| **Cost** | ~3-5% CPU overhead on write-heavy workloads | Worth 100x the cost savings from avoiding data loss |

### Real-World Scenarios Caught by Checksums

**Scenario 1: Storage Hardware Fault**
- SSD controller silent memory error → corrupts 8KB page
- Without checksums: Corrupt row returned to application; application trusts it
- With checksums: PostgreSQL page checksum fails on next read → error in log → alert sent → action taken before data leaves database

**Scenario 2: OS Memory Corruption**
- Kernel bug causes page cache to corrupt a buffer
- Without checksums: Silent corruption, possibly replicated to standbys
- With checksums: Detected on replica when page is read → replica detected corruption independently

**Scenario 3: Controller Cache Issue**
- NVMe controller battery-backed cache fails mid-write
- Without checksums: Partial write to disk undetected; incomplete row returned
- With checksums: Checksum fails; missing transaction detected

### PostgreSQL 18 Default Behavior
```sql
-- PostgreSQL 18+ has checksums ON by default for new clusters
SHOW data_checksums;
-- Result: on
```

**For upgrades from PG 17 or earlier:**
```bash
# Re-enable checksums on existing cluster (requires downtime):
sudo systemctl stop postgresql@18-primary.service
/usr/lib/postgresql/18/bin/pg_checksums -D /data/primary --enable
sudo systemctl start postgresql@18-primary.service
```

### The Cost-Benefit Analysis
- **CPU Overhead**: ~3-5% on write-heavy workloads (read-only: <0.5%)
- **Storage Overhead**: 0 bytes (checksum stored in existing page header)
- **Detection Value**: Catches storage faults that would cost $$$$ in data loss + audit penalties
- **SLA Impact**: Early detection means short recovery vs. weeks of forensics

**Recommendation for Production:**  
✅ **Always enable checksums**. The 3-5% CPU cost is trivial compared to even a single data loss incident.

### Check Checksum Status
```sql
-- Quick check:
SHOW data_checksums;

-- Detailed check:
SELECT name, setting FROM pg_settings WHERE name = 'data_checksums';
```

---

## 🏗️ Integrated Diagnosis & Recovery Pipeline

### Phase 1: Identify Corruption Source
```
ERROR seen in log
  ↓
grep "ERROR" /var/log/postgresql/postgresql-18-primary.log
  ↓
Extract: base/<OID>/<RELFILENODE> block <N>
  ↓
pg_database OID → database name
  ↓
pg_class relfilenode → table + schema
  ↓
IDENTIFY: Corrupted table is payment_transactions.public block 2
```

### Phase 2: pg_checksums Validation (DB STOPPED)
```
sudo systemctl stop postgresql@18-primary.service
  ↓
/usr/lib/postgresql/18/bin/pg_checksums --check -D /data/primary
  ↓
Compare on-page checksum vs computed checksum
  ↓
Result: "Checksum verification failed on file base/5/16482 block 2"
  ↓
Confirms: Block is physically corrupted at byte level (silent corruption detected)
```

### Phase 3: pageinspect Fine-Grained Analysis (DB RUNNING)
```sql
-- Install first:
CREATE EXTENSION IF NOT EXISTS pageinspect;

-- Read raw 8KB page structure:
SELECT * FROM page_header(get_raw_page('payment_transactions', 2));
-- Result: LSN, checksum value, pd_lower, pd_upper, free space pointers

-- Inspect individual tuple headers:
SELECT * FROM heap_page_items(get_raw_page('payment_transactions', 2));
-- Result: Item slot, ctid, xmin (transaction ID), xmax, infomask flags, tuple layout
```

### Phase 4: amcheck Logical Verification (DB RUNNING)
```sql
-- Install first:
CREATE EXTENSION IF NOT EXISTS amcheck;

-- Check heap integrity:
SELECT verify_heapam('payment_transactions'::regclass);
-- Result: NULL = healthy | Error msg = logical corruption found

-- Check index cross-references (deep check):
SELECT bt_index_parent_check('idx_payment_status'::regclass, heapallindexed => TRUE);
-- Result: NULL = all index entries match heap tuples | Error = index/heap mismatch
```

### Phase 5: Block-Level Decision Matrix

| Corruption Type | Detection Tool | Action | Tool Chain |
|---|---|---|---|
| **Checksum mismatch** (silent) | pg_checksums | Copy block from replica via dd | systemctl stop + dd + systemctl start |
| **Unreadable page header** | pageinspect | Full table recovery from replica | pg_dump from replica → restore |
| **HOT chain broken** | amcheck | REINDEX if index, else recovery | amcheck → REINDEX / recovery |
| **NULL bitmap corrupted** | amcheck verify_heapam | Full table recovery | pg_dump from replica → restore |
| **Multiple corrupt blocks** | pageinspect + amcheck | Full table/database recovery | pg_basebackup or replica recovery |

### Phase 6: Recovery Strategy Decision
```
Count corrupt blocks from Phase 3-4 results
  ↓
IF 1-2 blocks:
  └─→ Surgical repair: dd from replica block → primary block
  └─→ Tools: dd, systemctl
  └─→ Safe when: Block number verified 3x, replica in sync
  └─→ Least disruptive
  
IF 3+ blocks OR unreadable header:
  └─→ Full table recovery: pg_dump from replica → restore
  └─→ Tools: pg_dump, psql, REINDEX, ANALYZE
  └─→ Safe when: Replica LSN ≤ Primary, replica in sync
  
IF entire database affected:
  └─→ Full database recovery: pg_basebackup from replica
  └─→ Tools: pg_basebackup, rsync
  └─→ Involves downtime
```

### Phase 7: Post-Recovery Verification
```sql
-- After recovery:

-- 1) Verify row count matches replica:
SELECT count(*) FROM payment_transactions;

-- 2) Check specific PKs are now readable:
SELECT * FROM payment_transactions WHERE txn_id IN (101, 205, 398);

-- 3) Rebuild indexes:
REINDEX TABLE payment_transactions;

-- 4) Refresh statistics:
ANALYZE payment_transactions;

-- 5) Final amcheck validation:
SELECT bt_index_parent_check('idx_payment_status'::regclass, heapallindexed => TRUE);
```

---

## 🔗 Tool Integration Quick Reference

### Read-Only Diagnosis (Production Safe)
```
ERROR log → pg_database (OID) → pg_class (relfilenode) 
  ↓ (DB running)
pageinspect (raw page bytes) + amcheck (logical rules)
  ↓
Categorize: Checksum? TOAST? HOT chain? NULL bitmap?
```

### Repair Decision (With Backup)
```
Corrupt block count & type → Decision matrix (above)
  ↓
IF surgical: systemctl stop + dd + systemctl start + verify
  ↓
IF full table: pg_dump (replica) + psql (restore) + REINDEX + ANALYZE + verify
  ↓
IF full DB: pg_basebackup + cut over + verify
```

### Prerequisites Checklist
```bash
# Before starting investigation:
✓ pg_lsclusters                          # Know all cluster ports
✓ systemctl status postgresql@18-*       # All clusters running?
✓ pg_stat_replication                    # Replica in sync?
✓ SHOW data_directory                    # Know PGDATA paths
✓ SHOW data_checksums                    # Checksums enabled?
✓ CREATE EXTENSION pageinspect           # Lab tools installed?
✓ CREATE EXTENSION amcheck               # Lab tools installed?
✓ Take backup: pg_backup_start() + rsync # Have escape route?
```

---

## 🔧 Surgical Block Repair (1–2 Corrupt Blocks from Replica)

### When to Use Surgical Repair vs Full Recovery
| Condition | Method |
|-----------|--------|
| 1–2 corrupt blocks, replica in sync | ✅ Surgical: `dd` block copy from replica |
| 3+ corrupt blocks OR unreadable page header | ❌ Skip surgical → Full table `pg_dump` |
| Entire schema/database affected | ❌ Skip surgical → Full `pg_basebackup` |

### Step-by-Step: Surgical dd Block Repair

**Step 1: Get the corrupt block numbers from diagnosis**
```sql
-- Connect to primary:
sudo -u postgres psql -p 5432 -d postgres

-- Find corrupt blocks:
SELECT block_num, ctid_val, error_type
FROM v_corruption_latest
WHERE table_name = 'payment_transactions'
ORDER BY block_num;
-- Example result: block 2 → UNREADABLE_PAGE
```

**Step 2: Find the heap file path for the table**
```sql
-- Get relfilenode (physical file number):
SELECT pg_relation_filepath('payment_transactions');
-- Result: base/5/16482
```

**Step 3: Confirm replica is in sync and has a good copy of the block**
```sql
-- On primary — check replica lag:
SELECT application_name, replay_lag, sync_state FROM pg_stat_replication;
-- Safe when: replay_lag is seconds, NOT minutes
```

**Step 4: Stop the primary (REQUIRED before dd)**
```bash
sudo systemctl stop postgresql@18-primary.service
sudo systemctl is-active postgresql@18-primary.service
# Must show: inactive
```

**Step 5: Copy the single 8KB block from replica to primary**
```bash
# Syntax:
# dd if=<REPLICA_FILE> of=<PRIMARY_FILE> bs=8192 count=1 skip=<BLOCK_N> seek=<BLOCK_N> conv=notrunc
#
# For block 2 in this lab:
dd if=/data/replica2/base/5/16482 \
   of=/data/primary/base/5/16482 \
   bs=8192 count=1 skip=2 seek=2 conv=notrunc

# Explain each flag:
# bs=8192    → one operation = exactly one 8KB PostgreSQL page
# count=1    → copy exactly one block, no more
# skip=2     → start reading from block 2 on the SOURCE (replica)
# seek=2     → start writing at block 2 on the DESTINATION (primary)
# conv=notrunc → DO NOT truncate rest of file (critical!)
```

> ⚠️ **If block numbers don't match (skip ≠ seek), you corrupt a different block on production.**
> **Triple-check block numbers from v_corruption_latest before running dd.**

**Step 6: Start primary and verify**
```bash
sudo systemctl start postgresql@18-primary.service
sudo systemctl is-active postgresql@18-primary.service
# Must show: active
```

**Step 7: Verify the repaired block is now readable**
```sql
sudo -u postgres psql -p 5432 -d postgres

-- 1) Read repaired block header (should work without error):
SELECT * FROM page_header(get_raw_page('payment_transactions', 2));

-- 2) Read specific rows that were corrupt:
SELECT * FROM payment_transactions WHERE txn_id IN (101, 205, 398, 512, 777);

-- 3) Confirm row count matches replica:
SELECT count(*) FROM payment_transactions;

-- 4) Verify amcheck passes (no more heap violations):
SELECT bt_index_parent_check('idx_payment_status'::regclass, heapallindexed => TRUE);
-- NULL result = repair successful
```

### Multiple Blocks — Loop dd
```bash
# If blocks 2 AND 12 are corrupt (from diagnosis):
for block in 2 12; do
  echo "Repairing block $block..."
  dd if=/data/replica2/base/5/16482 \
     of=/data/primary/base/5/16482 \
     bs=8192 count=1 skip=$block seek=$block conv=notrunc
done
```

### Safety Mental Checklist Before dd
```
✓ Primary PostgreSQL is STOPPED          (systemctl is-active → inactive)
✓ Replica file path is correct           (match OID and relfilenode)
✓ Primary file path is correct           (same OID and relfilenode)
✓ Block number matches in skip= and seek= (both = same corrupt block)
✓ conv=notrunc is present                (missing this truncates the file!)
✓ Backup taken already                   (pg_backup_start + rsync done)
✓ Replica lag was low (seconds not hours) (replica is fresh copy)
```

---

## 📦 Table-Level Restore from Replica

### When to Use
- 3+ corrupt blocks on a single table
- Page header is completely unreadable (pageinspect throws error)
- Surgical `dd` is too risky (too many non-contiguous blocks)
- Replica is healthy and in sync

### Step-by-Step: pg_dump Table Restore

**Step 1: Confirm replica is healthy and in sync**
```sql
-- On primary:
SELECT application_name, replay_lag, sync_state, state
FROM pg_stat_replication;
-- SAFE when: replay_lag < 30s, state = streaming
```

**Step 2: Take backup FIRST (escape route)**
```sql
-- On primary (DB stays online):
SELECT pg_backup_start('pre_restore_backup', false);
```
```bash
rsync -ar /data/primary/ /data/backup/
```
```sql
SELECT * FROM pg_backup_stop();
```

**Step 3: Count corrupt rows to decide scope**
```sql
SELECT * FROM v_row_diagnosis_summary ORDER BY corrupt_rows DESC;
-- If corrupt_pct > 20% → consider full DB restore instead
```

**Step 4: Dump the healthy table from REPLICA (port 5434)**
```bash
/usr/lib/postgresql/18/bin/pg_dump \
  -U postgres \
  -d postgres \
  -p 5434 \
  -t payment_transactions \
  > /data/backup/transactions_backup.sql

# Verify dump file is not empty:
wc -l /data/backup/transactions_backup.sql
ls -lh /data/backup/transactions_backup.sql
```

**Step 5: Rename corrupt table (keep as forensic reference)**
```sql
-- Connect to primary:
sudo -u postgres psql -p 5432 -d postgres

-- Rename, don't drop:
ALTER TABLE public.payment_transactions
  RENAME TO payment_transactions_corrupted;
```

**Step 6: Restore clean table from dump**
```bash
psql -U postgres -d postgres -p 5432 \
  -f /data/backup/transactions_backup.sql
```

**Step 7: Rebuild indexes and refresh statistics**
```sql
REINDEX TABLE public.payment_transactions;
ANALYZE public.payment_transactions;
```

**Step 8: Verify restore**
```sql
-- Row count matches replica?
SELECT count(*) FROM payment_transactions;           -- restored
SELECT count(*) FROM payment_transactions_corrupted; -- old corrupt copy

-- Previously corrupt PKs now readable?
SELECT * FROM payment_transactions WHERE txn_id IN (101, 205, 398, 512, 777);

-- amcheck passes?
SELECT bt_index_parent_check('idx_payment_status'::regclass, heapallindexed => TRUE);
-- NULL = all good

-- pg_dump health check on primary:
pg_dump -U postgres -p 5432 -d postgres --schema=public -f /dev/null 2>&1 | grep -i error
```

**Step 9: Drop corrupt copy only after verify**
```sql
-- Only run after Step 8 all passes:
DROP TABLE public.payment_transactions_corrupted;
```

---

## 🚦 To Failover or Not to Failover — Confirm Score Before Action

### The Key Question
> "Is the primary recoverable in-place, or is failover to a replica faster and safer?"

### Score Your Situation (add up points)

| Check | Condition | Score |
|-------|-----------|-------|
| **Corruption scope** | Single table, 1-3 blocks | +0 (stay) |
| | Multiple tables OR entire schema | **+3 (failover)** |
| | System catalogs corrupt (pg_class, pg_database) | **+5 (failover NOW)** |
| **Time to repair** | Surgical dd < 15 min | +0 (stay) |
| | Table restore < 30 min | +1 (stay or failover) |
| | Estimate > 1 hour | **+3 (failover)** |
| **Replica lag** | < 30 seconds | +0 (replica is safe) |
| | 30s – 5 min | +1 (check carefully) |
| | > 5 min OR replica disconnected | **+4 (do NOT failover, replica may be stale)** |
| **Backup available** | Recent clean backup exists | +0 |
| | No backup OR backup is corrupt | **+2 (failover more risky too)** |
| **Primary service** | Still running, accepting connections | +0 (stay) |
| | Crashed: restart fails | **+3 (failover)** |
| **User impact** | No users currently affected | +0 |
| | SLA breach in progress | **+2 (failover urgency)** |

### Decision by Score

| Total Score | Decision | Action |
|-------------|----------|--------|
| **0 – 2** | ✅ Stay on primary | Surgical dd or table restore |
| **3 – 5** | ⚠️ Lean toward failover | Check replica lag first, then decide |
| **6 – 9** | 🔴 Failover recommended | Promote replica, redirect traffic |
| **10+** | 🚨 Emergency failover | Promote NOW, investigate primary later |

### Pre-Failover Checklist (run ALL before promoting)
```sql
-- 1) Confirm replica is streaming (not in recovery lag):
SELECT state, sync_state, replay_lag FROM pg_stat_replication;
-- MUST: state = streaming, replay_lag < 30s

-- 2) Check replica has all recent WAL (LSN must be close to primary):
-- On PRIMARY:
SELECT pg_current_wal_lsn();
-- On REPLICA (connect -p 5433):
SELECT pg_last_wal_replay_lsn();
-- Gap should be small (few MB max)

-- 3) Confirm no transactions in-flight on primary that replica hasn't seen:
SELECT count(*) FROM pg_stat_activity WHERE state = 'active';
-- Ideally 0 active transactions before failover

-- 4) Confirm replica can be promoted:
sudo -u postgres psql -p 5433 -c "SELECT pg_is_in_recovery();"
-- Must return: t (true = it is a replica, ready to promote)
```

### How to Promote Replica (if score says failover)
```bash
# Method 1: pg_ctl promote (graceful)
/usr/lib/postgresql/18/bin/pg_ctl promote -D /data/replica1

# Method 2: trigger file (older clusters)
touch /data/replica1/failover.trigger

# Method 3: via psql signal (PostgreSQL 12+)
sudo -u postgres psql -p 5433 -c "SELECT pg_promote();"
```

### Post-Failover Checklist
```sql
-- 1) Confirm new primary is NO longer in recovery:
SELECT pg_is_in_recovery();
-- Must return: f (false = it is now primary)

-- 2) Confirm it accepts writes:
CREATE TABLE failover_test (id int);
DROP TABLE failover_test;

-- 3) Check timeline advanced:
SELECT timeline_id FROM pg_control_checkpoint();
-- Should be previous timeline + 1

-- 4) Update application connection strings to new primary port
-- 5) Rebuild old primary as new replica once it's repaired
```

### Failover vs Restore — Summary Table

| Factor | Table Restore (Stay) | Failover |
|--------|---------------------|----------|
| Corruption scope | 1 table, few blocks | Multi-table or system catalogs |
| Time to fix | Minutes | Seconds (promote) |
| Replica freshness needed | Less critical | Critical — must be in sync |
| Risk | Low | Medium (data loss if replica is behind) |
| Downtime | Minimal | Brief (redirect connections) |
| When primary crashes | Not applicable | Only option |

---

## ⛔ COMMANDS TO AVOID (Prevents Further Corruption)

**DO NOT RUN THESE** — They will cause data loss or additional corruption:

### 1) Corrupt Data Intentionally
```bash
python3 03b_corrupt_records.py \
    --db postgres \
    --table payment_transactions \
    --pk txn_id \
    --pk-values 101 205 398 512 777
```
**Why:** Permanently overwrites bytes in heap file. **Lab only.**

### 2) Drop Corrupted Table Without Backup
```sql
DROP TABLE public.payment_transactions;
```
**Why:** Deletes entire table. Cannot recover without backup. **Only after verify recovery is complete.**

### 3) Stop Database Without Planning
```bash
sudo systemctl stop postgresql@18-primary.service
```
**Why:** Disconnects all users. Only stop during planned maintenance window.

### 4) Direct Disk Write with dd (Wrong Block)
```bash
dd if=/data/replica2/base/5/16482 \
   of=/data/primary/base/5/16482 \
   bs=8192 count=1 skip=2 seek=2 conv=notrunc
```
**Why:** If skip= or seek= are wrong, corrupts MORE blocks. **Verify block number 3x first.**

### 5) Cluster-Wide Checksum Scan Without Stopping DB
```bash
/usr/lib/postgresql/18/bin/pg_checksums --check -D /data/primary
```
**Why:** Requires cluster to be STOPPED. Database must not be running.

### 6) Rename Corrupt Table
```sql
ALTER TABLE payment_transactions RENAME TO payment_transactions_corrupted;
DROP TABLE public.payment_transactions;
```
**Why:** Use script-based rename, not manual DDL. Risk of losing data path reference.

## What IS Safe to Run Immediately

```sql
SHOW data_directory;
SELECT datname FROM pg_database WHERE oid = '5';
SELECT * FROM pg_stat_replication;
SELECT count(*) FROM payment_transactions;
SHOW data_checksums;
```

## Quick Typos to Avoid
- Correct: `systemctl status postgresql@18-<cluster-name>.service`
- Not: `systemctl stsud postres@18-<cluster-name>.service`




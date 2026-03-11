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





---

## ⚠️ Usual Causes of PostgreSQL Data Corruption

Understanding the root cause first prevents the same incident from recurring.

### 1. Storage Hardware Failure
- **What:** SSD/HDD silently returns wrong bytes (bit rot), controller drops writes, NVMe write cache fails
- **Why dangerous:** No error raised at OS level — PostgreSQL reads corrupt data without knowing
- **Detection:** `pg_checksums --check` (offline) or checksum mismatch error in log
- **Prevention:** Enable data checksums; use enterprise-grade storage with BBU (battery-backed unit)

### 2. Power Loss During Write Operation
- **What:** Server loses power mid-write — partial 8KB page written to disk; the other half is stale
- **Why dangerous:** Page contains a mix of old and new data — logically and physically inconsistent
- **Detection:** "invalid page in block N" in PostgreSQL log on next startup read
- **Prevention:** UPS on database servers; `fsync = on` (default); battery-backed RAID controller

### 3. Defective RAM / CPU Issue
- **What:** Faulty DIMM silently flips bits in shared_buffers before they are flushed to disk; CPU ECC errors corrupt in-flight data
- **Why dangerous:** PostgreSQL writes what's in RAM — if RAM is wrong, the on-disk page will be wrong too
- **Detection:** Random checksum failures across unrelated tables; `memtest86` shows errors
- **Prevention:** ECC RAM mandatory in production; periodic memory diagnostics; `SHOW shared_buffers;`

### 4. Filesystem or OS-Level Bugs
- **What:** Kernel VFS bug, ext4/XFS journal corruption, or OS page cache mishandling flips bytes before flush
- **Why dangerous:** PostgreSQL trusts the OS to deliver what it wrote — a buggy FS betrays that trust
- **Detection:** Filesystem errors in `dmesg` or `journalctl -k`; checksum failures after kernel upgrade
- **Prevention:** Use XFS or ext4 with `barriers=1`; keep kernel patched; run `fsck` after unclean shutdown

### 5. PostgreSQL Software Bugs
- **What:** Rare but real — bugs in WAL replay, VACUUM, autovacuum, or index builds can produce corrupt pages in specific versions
- **Why dangerous:** Affects many clusters running the same version simultaneously
- **Detection:** Corruption always in same type of operation; PostgreSQL release notes list known bugs
- **Prevention:** Track PostgreSQL CVEs; upgrade to latest minor version; test upgrades on staging first

### 6. Misconfiguration: `fsync = off`
- **What:** Disabling fsync tells PostgreSQL NOT to wait for data to be flushed to disk — fastest possible writes, but zero durability
- **Why dangerous:** Any OS crash/power loss = entire data directory is corrupt; pages are half-written everywhere
- **Detection:** After crash, `pg_checksums --check` reports hundreds of failures across all tables
- **Prevention:** **NEVER set `fsync = off` in production.** Only acceptable for ephemeral test clusters.
```sql
-- Verify fsync is ON:
SHOW fsync;           -- must return: on
SHOW synchronous_commit;  -- at minimum: local
```
```bash
# Common wrong advice online — DO NOT DO THIS IN PRODUCTION:
# fsync = off              ← instant data corruption on any crash
# full_page_writes = off   ← unsafe if combined with any storage fault
```

### 7. Incorrect or Unsafe Backup
- **What:** Copying data directory files while PostgreSQL is running without `pg_backup_start()` → inconsistent snapshot; restoring it produces corrupt cluster
- **Why dangerous:** Files copied at different points in time are mutually inconsistent (some pages are mid-WAL-replay)
- **Detection:** Restored cluster fails to start: "WAL file not found" or "invalid checkpoint record"
- **Prevention:** Always use `pg_basebackup` or `pg_backup_start()` + rsync + `pg_backup_stop()`; NEVER cold-copy a live data dir

### 8. Unsafe Use of `pg_resetwal`
- **What:** `pg_resetwal` resets the WAL write position and transaction IDs — intended only for unrecoverable clusters as last resort
- **Why dangerous:** Discards transaction history → MVCC state is now inconsistent → silent data loss; index/heap divergence
- **Detection:** Queries return wrong rows; amcheck reports HOT chain and MVCC violations after reset
- **Prevention:** Never run without PostgreSQL support guidance; always try PITR first
```bash
# NEVER run this without expert guidance:
# /usr/lib/postgresql/18/bin/pg_resetwal -D /data/primary   ← last resort only
```

### 9. Manual Tampering of the Data Directory
- **What:** Directly editing, moving, or deleting files inside PGDATA while PostgreSQL is running or without checksums re-validation
- **Why dangerous:** PostgreSQL maintains strict internal consistency between heap files, WAL, and pg_control — any manual edit breaks this
- **Detection:** Immediate crash on next query touching that relation; "could not read block N" errors
- **Prevention:** Never `rm`, `mv`, or edit anything inside `/data/primary/` directly; use only PostgreSQL tools

---

### Root Cause Quick Reference

| Cause | Layer | Detected By | Prevented By |
|-------|-------|-------------|--------------|
| Storage hardware failure | Hardware | `pg_checksums`, log errors | ECC storage, checksums |
| Power loss mid-write | Hardware | Log on restart, checksums | UPS, `fsync=on`, BBU |
| Defective RAM | Hardware | Random checksum failures | ECC RAM, memtest |
| Filesystem/OS bug | OS | `dmesg`, checksum failures | Patched kernel, XFS/ext4 |
| PostgreSQL bug | Software | Specific version pattern | Minor version upgrades |
| `fsync = off` | Config | Mass failures after crash | **Never disable fsync** |
| Unsafe backup restore | Operational | Cluster won't start | `pg_basebackup` only |
| `pg_resetwal` misuse | Operational | MVCC/index violations | Expert guidance only |
| Manual data dir edit | Operational | Immediate crash/error | Never touch PGDATA directly |

---

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

---

## 🚦 To Failover or Not to Failover — Three Paths

### The Three Options at a Glance

| Path | When | Speed | Risk | Data Loss |
|------|------|-------|------|-----------|
| **Immediate Failover** | Primary crashed / unrecoverable | Fastest (seconds) | Medium — replica may lag | Seconds–minutes of uncommitted txns |
| **Pause & Investigate** | Primary still running, corruption isolated | Slower (minutes–hours) | Low — controlled repair | Zero if replica in sync |
| **PITR Recovery** | Both primary and replica corrupt / no replica | Slowest (hours) | Low if backup is clean | From last clean backup to incident |

---

### Path 1 — Immediate Failover

**Use when:**
- Primary PostgreSQL process is dead and won't restart
- System catalogs (`pg_class`, `pg_database`) are corrupt
- Failover scorecard (above) = 6+

**Steps:**
```bash
# 1. Confirm replica is streaming and fresh:
sudo -u postgres psql -p 5433 -c "SELECT pg_is_in_recovery(), pg_last_wal_replay_lsn();"

# 2. Compare LSN with primary (if still reachable):
sudo -u postgres psql -p 5432 -c "SELECT pg_current_wal_lsn();"
# Gap < few MB = safe to promote

# 3. Promote the replica:
sudo -u postgres psql -p 5433 -c "SELECT pg_promote();"

# 4. Confirm promoted (no longer in recovery):
sudo -u postgres psql -p 5433 -c "SELECT pg_is_in_recovery();"
# Must return: f

# 5. Redirect applications to new primary (port 5433)
```

**Acceptable data loss window:**
- Only transactions that were committed on primary but NOT yet replayed on replica
- Check with: `pg_current_wal_lsn()` (primary) vs `pg_last_wal_replay_lsn()` (replica)
- If gap = 0 → zero data loss. If gap > 0 → those WAL bytes are lost.

**After failover:**
```sql
-- Verify timeline advanced:
SELECT timeline_id FROM pg_control_checkpoint();
-- Should be old_timeline + 1

-- Confirm writes work:
CREATE TABLE failover_test(id int); DROP TABLE failover_test;
```

---

### Path 2 — Pause & Investigate (Stay on Primary)

**Use when:**
- Primary is still running and accepting connections
- Corruption is isolated to 1–2 blocks or a single table
- Replica lag < 30 seconds

**Investigation Steps (DO NOT WRITE anything until diagnosis is complete):**

```sql
-- Step 1: Identify corrupt blocks:
SELECT block_num, error_type, ctid_val
FROM v_corruption_latest
WHERE table_name = 'payment_transactions'
ORDER BY block_num;

-- Step 2: Check how many blocks are bad:
SELECT * FROM v_row_diagnosis_summary;
-- corrupt_pct < 5% with 1-2 blocks → surgical dd
-- corrupt_pct > 10% or 3+ blocks  → table restore
-- multiple tables affected          → CONSIDER failover

-- Step 3: Verify replica is healthy first:
SELECT application_name, replay_lag, sync_state FROM pg_stat_replication;
```

**Then pick the right repair sub-path:**
```
1-2 corrupt blocks → Surgical dd repair   (see 🔧 Surgical Block Repair section)
3+ blocks, 1 table → Table-level restore  (see 📦 Table-Level Restore section)
Full DB affected   → pg_basebackup restore OR failover
```

**Key principle:**  
> Pause first. Collect evidence. Then act. Never write to a corrupt block without a backup.

---

### Path 3 — PITR (Point-In-Time Recovery)

**Use when:**
- No healthy replica available
- Replica is also corrupt (replicated corruption)
- Need to recover to a state BEFORE the corruption was introduced
- Bad migration or bulk DELETE wiped data (logical corruption, not physical)

**How PITR works:**
```
pg_basebackup (clean base backup)
  +
WAL archive files (incremental changes)
  =
Any point in time between backup and now
```

**Steps:**

```bash
# Step 1: Stop the corrupt primary:
sudo systemctl stop postgresql@18-primary.service

# Step 2: Identify when corruption was introduced (from log):
grep -i "checksum\|invalid page\|ERROR" /var/log/postgresql/postgresql-18-primary.log | head -30
# Note the TIMESTAMP of first corruption error

# Step 3: Restore base backup to a clean directory:
rsync -ar /data/backup/ /data/recovery/

# Step 4: Create recovery config (PostgreSQL 12+ uses postgresql.conf):
cat >> /data/recovery/postgresql.conf << 'EOF'
restore_command = 'cp /data/wal_archive/%f %p'
recovery_target_time = '2026-03-11 09:45:00'   # just BEFORE corruption
recovery_target_action = 'promote'
EOF

# Create signal file to enter recovery mode:
touch /data/recovery/recovery.signal

# Step 5: Start recovery instance:
/usr/lib/postgresql/18/bin/pg_ctl -D /data/recovery start

# Step 6: Watch logs until recovery reaches target time:
tail -f /var/log/postgresql/postgresql-18-recovery.log
# Look for: "recovery stopping before commit of transaction..."
```

**Find the exact recovery target time:**
```sql
-- If you know the corrupt PKs (101, 205, 398), find when they were last good:
-- Connect to replica or backup and check:
SELECT txn_id, xmin, created_at FROM payment_transactions
WHERE txn_id IN (101, 205, 398)
ORDER BY created_at DESC;
-- Set recovery_target_time to just before the corrupt timestamp
```

**PITR Verification after recovery:**
```sql
-- 1) Check data is clean:
SELECT * FROM payment_transactions WHERE txn_id IN (101, 205, 398, 512, 777);

-- 2) Row count looks right:
SELECT count(*) FROM payment_transactions;

-- 3) amcheck passes:
SELECT bt_index_parent_check('idx_payment_status'::regclass, heapallindexed => TRUE);

-- 4) Promote fully (stop WAL replay, make writable):
SELECT pg_promote();
```

---

### Decision Flowchart — Which Path?

```
Corruption detected
        ↓
Is the PRIMARY still running?
  ├── NO → Immediate Failover (Path 1)
  └── YES
        ↓
    Is a healthy replica available with lag < 30s?
      ├── NO → PITR Recovery (Path 3)
      └── YES
              ↓
          How many tables/blocks are corrupt?
            ├── 1 table, 1-2 blocks → Pause & Investigate → Surgical dd (Path 2)
            ├── 1 table, 3+ blocks  → Pause & Investigate → Table restore (Path 2)
            ├── Multiple tables, <1hr to fix → Pause & Investigate (Path 2)
            └── System catalogs corrupt OR estimate >1hr → Immediate Failover (Path 1)
```

---

### Data Loss Comparison

| Path | Data at Risk | How to Minimize |
|------|-------------|-----------------|
| Immediate Failover | Transactions committed on primary but not replayed on replica | Use sync replication (`synchronous_commit = on`) |
| Pause & Investigate | Zero — primary stays up, replica not disturbed | Complete repair before any failover |
| PITR | All changes from backup time to `recovery_target_time` | Run more frequent base backups + WAL archiving |

### PITR Key Config Parameters
```sql
-- Check WAL archiving is enabled:
SHOW archive_mode;    -- must be: on
SHOW archive_command; -- must show your copy command
SHOW wal_level;       -- must be: replica or logical
```




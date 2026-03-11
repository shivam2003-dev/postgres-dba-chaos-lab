# Scenario 3 Runbook

## PostgreSQL Ransomware Simulation and PITR Recovery

**Environment:** Primary (`5432`) | Replica1 (`5433`) | Replica2 (`5434`)

---

## Step 1: Pre-Attack Validation

Verify that all three nodes have the same clean data before the attack.

```bash
psql -p 5432 -c "SELECT * FROM products;"
psql -p 5433 -c "SELECT * FROM products;"
psql -p 5434 -c "SELECT * FROM products;"
```

**Expected result:** all three nodes should display identical product data.

---

## Step 2: Execute the Ransomware Simulation

Run the simulation script.

This script will:
- insert new rows into `products`,
- encrypt product columns using `pgp_sym_encrypt` (`pgcrypto`),
- create a `ransom_note` table,
- drop `README_RESTORE.txt` files to disk,
- rename table files in `base/5/` to `*.locked`, and
- rename WAL files in `pg_wal/` to `*.locked`.

```bash
bash scripts/sim3.sh
```

---

## Step 3: Confirm Damage on the Primary

### 3.1 Try Reading the `products` Table

```bash
psql -p 5432 -c "SELECT * FROM products;"
```

### 3.2 Monitor PostgreSQL Logs

```bash
tail -f /var/log/postgresql/postgresql-18-primary.log | grep -C5 SELECT
```

### 3.3 Recheck Primary and Replica Data

```bash
psql -p 5432 -c "SELECT * FROM products;"
psql -p 5433 -c "SELECT * FROM products;"
psql -p 5434 -c "SELECT * FROM products;"
```

---

## Step 4: Inspect the Data Directory and OID Information

### 4.1 List User Tables on the Primary

```bash
psql -p 5432 -c "SELECT schemaname, tablename
                 FROM pg_tables
                 WHERE schemaname NOT IN ('pg_catalog', 'information_schema');"
```

### 4.2 Get the Data Directory and Current Database OID

```bash
psql -p 5432 -c "SHOW data_directory;
                 SELECT oid, datname
                 FROM pg_database
                 WHERE datname = current_database();"
```

### 4.3 List Locked Table Files

```bash
ls /data/primary/base/5/
```

### 4.4 Read the Ransom Note

```bash
cat /data/primary/base/5/README_RESTORE.txt
```

### 4.5 List Locked WAL Files

```bash
ls /data/primary/pg_wal/
```

### 4.6 Check Cluster Control Data

```bash
/usr/lib/postgresql/18/bin/pg_controldata /data/primary
```

---

## Step 5: Assess Replica Status

Verify which replica still has clean data.

```bash
psql -p 5433 -c "SELECT * FROM products;"
psql -p 5434 -c "SELECT * FROM products;"
```

> Replica2 (`5434`) has a `90-minute recovery_min_apply_delay`, so it may still contain clean pre-attack data.

---

## Step 6: Pause WAL Replay on Both Replicas

Immediately pause replay to prevent the attack from propagating further.

```bash
psql -p 5433 -c "SELECT pg_wal_replay_pause();"
psql -p 5434 -c "SELECT pg_wal_replay_pause();"
```

Confirm replay positions:

```bash
psql -p 5433 -c "SELECT pg_is_in_recovery(),
                        pg_last_wal_replay_lsn(),
                        pg_last_wal_receive_lsn();"

psql -p 5434 -c "SELECT pg_is_in_recovery(),
                        pg_last_wal_replay_lsn(),
                        pg_last_wal_receive_lsn();"
```

---

## Step 7: Check Replica2 and Backup Health

### 7.1 Check Row Count on Replica2

```bash
psql -p 5434 -c "SELECT count(*) FROM products;"
```

### 7.2 Check Replication Lag on Replica2

```bash
psql -p 5434 -c "SELECT now() - pg_last_xact_replay_timestamp() AS lag;"
```

### 7.3 Verify Checksums on Replica2

```bash
/usr/lib/postgresql/18/bin/pg_checksums -D /data/replica2
```

### 7.4 Check `pgBackRest` Status

```bash
pgbackrest --stanza=primary info
```

### 7.5 List Available Archived WAL Files

```bash
ls -l /var/lib/pgbackrest/archive/primary/18-1/
```

---

## Step 8: Execute PITR Recovery on Replica2

Run the recovery script to restore Replica2 to a point before the attack.

```bash
bash scripts/replica_recovery.sh
```

> Ensure the target recovery time is set to **before** the attack timestamp captured in `/data/primary/.time.txt`.

---

## Step 9: Resume Replay and Promote Replica2

### 9.1 Resume WAL Replay

```bash
psql -p 5434 -c "SELECT pg_wal_replay_resume();"
```

### 9.2 Confirm Promotion

```bash
psql -p 5434 -c "SELECT pg_is_in_recovery();"
```

**Expected result:** `f` meaning Replica2 is now acting as the primary.

---

## Step 10: Validate Recovered Data on Replica2

### 10.1 Confirm the `products` Table Is Clean

```bash
psql -p 5434 -c "SELECT * FROM products;"
```

### 10.2 Analyze and Verify Live Tuple Count

```bash
psql -p 5434 -c "ANALYZE;
                 SELECT schemaname, relname, n_live_tup
                 FROM pg_stat_user_tables
                 WHERE relname = 'products'
                 ORDER BY n_live_tup DESC;"
```

**Expected result:** `n_live_tup` should match the clean pre-attack row count.

---

## Recovery Complete

**New Primary:** Replica2 on port `5434`  
**Status:** `products` table restored to the pre-attack state

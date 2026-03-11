# Scenario 2 — High Latency & Slow Performance
---
## 🚨 The Alert

> **"API response times have spiked. Queries that normally take 5ms are now taking 3–10 seconds. Users are seeing timeouts. Incident raised."**

- **Symptom:** Application reporting high latency, slow DB response, intermittent timeouts
- **Environment:** PostgreSQL 18, primary + replicas + logical subscriber (`analytics`)
- **First instinct:** Check if the database is under load, or if something is holding resources
---
## 🧭 Applying the Incident Response Loop

### DETECT → DIAGNOSE → MITIGATE → RESOLVE → LEARN

---

## Phase 1 — DETECT: First Alert — Replica Lag Spike

The database feels slow. Start with **read-only observation** — do not change anything yet.

### 1.1 Check Streaming Replication Health (Primary)

```sql
SELECT
  client_addr,
  application_name,
  state,
  sent_lsn,
  write_lsn,
  replay_lag,
  pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS lag_bytes
FROM pg_stat_replication;
```

**What to look for:**
| Signal | Meaning |
|--------|---------|
| `replay_lag` > 10s | Replica is falling behind — primary is waiting or generating too much WAL |
| `lag_bytes` growing | WAL is not being consumed fast enough by replica |
| `state = catchup` | Replica reconnected and is replaying — normal after brief disconnect |
| No rows returned | No replicas connected at all — check if replica crashed |

### 1.2 Inspect Replication Slots

```sql
SELECT
  slot_name,
  slot_type,
  active,
  restart_lsn,
  pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal,
  wal_status
FROM pg_replication_slots
ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC;
```

**What to look for:**
| Signal | Meaning |
|--------|---------|
| `active = false` with large `retained_wal` | Orphaned slot — primary is holding WAL for a dead consumer |
| `wal_status = lost` | Slot is so far behind that WAL segments were recycled — slot is broken |
| `wal_status = extended` | PostgreSQL extended WAL retention beyond `max_wal_size` for this slot |
| Large `retained_wal` on any slot | Root cause of disk pressure and potential latency |

### 1.3 Check Disk Pressure (Shell)

```bash
df -h /data
du -sh /data/primary/pg_wal/
```

**What to look for:**
- `/data` disk usage > 80% → immediate risk
- `pg_wal/` directory is unusually large (should be ~1–2x `max_wal_size`)
- Large `pg_wal/` combined with an inactive replication slot = **WAL flood** (see Phase 2)

---

## Phase 2 — DIAGNOSE: WAL Flood & Disk Pressure

### Why WAL Floods Cause Latency

```
Inactive replication slot (analytics_slot)
  ↓
PostgreSQL CANNOT recycle WAL segments (slot holds restart_lsn back)
  ↓
pg_wal/ directory grows unboundedly
  ↓
Disk fills up → checkpoint stalls → fsync queue backs up
  ↓
Write queries start waiting → latency spikes for all users
```

### 2.1 Monitor WAL Accumulation Live

```bash
watch -n 1 'psql -c "
SELECT slot_name, wal_status,
  pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained
FROM pg_replication_slots;"'
```

**Short explanation:**
- `watch -n 1` = rerun the command every 1 second
- `psql -c` = run one SQL command from the shell
- `pg_replication_slots` = shows replication slot status
- `retained` = how much WAL each slot is forcing PostgreSQL to keep

Track WAL directory growth in parallel from the shell:

```bash
watch -n 1 'du -csh /data/primary/pg_wal'
```

**Short explanation:**
- `watch -n 1` = refresh every 1 second
- `du -csh` = show folder size in human-readable form and print a total
- `/data/primary/pg_wal` = the folder where WAL files are stored
- If this number keeps growing fast, WAL is piling up

**Expected healthy output:** `retained` < 500MB per slot  
**Red flag:** `retained` > 1GB and `active = false`

### 2.2 Verify Archive Failures

```sql
SELECT
  failed_count,
  last_failed_time,
  now() - last_archived_time AS time_since_last_archive
FROM pg_stat_archiver;
```

**Why this matters:**
- If WAL archiving is failing + slot is holding WAL → double WAL retention → disk fills 2x faster
- Archive failure breaks PITR (Point-In-Time Recovery) — your backup safety net is gone

### 2.3 Check Disk Usage & Live Logs

```bash
# Disk snapshot:
df -h /data/primary

# Watch live logs for checkpoint warnings, archive errors:
tail -f /var/log/postgresql/postgresql-18-primary.log
```

**Key log messages to look for:**
```
LOG:  checkpoint complete: wrote X buffers ...
WARNING: out of shared memory
ERROR: could not write to file "pg_wal/..." : No space left on device
LOG:  archive command failed with exit code 1
```

### 2.4 Root Cause Identification Table

| Observation | Root Cause | Severity |
|-------------|-----------|----------|
| Inactive slot + growing `retained_wal` | Orphaned replication slot | 🟠 High |
| `wal_status = lost` | Slot too far behind — must drop | 🔴 Critical |
| Archive `failed_count` > 0 | Archive destination full/unreachable | 🟠 High |
| Disk > 90% on `/data` | Imminent write failure, checkpoints failing | 🔴 Critical |
| `replay_lag` > 30s on streaming replica | Network congestion / replica I/O overloaded | 🟡 Medium |

---

## Phase 3 — MITIGATE: Crisis — PITR Broken, Disk at 92%

> **Stop the bleeding before attempting repair.**

### Strategic Triage Sequence

This phase can be remembered as a simple 4-step triage flow:

1. **Immediate containment (Isolate)**
  - Reduce or stop the workload
  - Prevent the system from getting worse while you investigate

2. **Verify before acting (Analyze)**
  - Confirm the slot is really inactive
  - Check whether the subscriber is gone or just paused
  - Avoid making the wrong destructive change

3. **Execute the critical fix (Baseline)**
  - Drop the orphaned slot or re-enable the subscription
  - This is the action that removes the main blocker

4. **Reclaim and repair (Implement)**
  - Let WAL drain
  - force a checkpoint
  - verify disk recovery
  - take a fresh backup and return to a stable baseline

### Critical Safety Sequence

1. **Do not restart when disk is ~95% full**
  - A restart does not solve WAL retention
  - PostgreSQL may come back only to hit the same disk-pressure problem again
  - In very high disk usage conditions, restart can increase recovery stress and waste valuable time

2. **Do not drop a slot without verification**
  - First confirm whether the slot is inactive
  - Check if the subscriber is permanently gone or only paused
  - Dropping the wrong slot can break replication or logical decoding unnecessarily

3. **Always take a fresh base backup after fixing archive gaps**
  - If archiving was broken, PITR safety may have gaps
  - A new base backup gives you a clean recovery starting point
  - This restores confidence in backup + WAL recovery capability

### Step 1 — Stop or Throttle the Workload

```bash
# Stop the workload generator if in lab:
docker stop pg-workload
```

If you cannot stop the workload, throttle checkpoint I/O to reduce pressure:
```sql
ALTER SYSTEM SET checkpoint_completion_target = 0.9;
SELECT pg_reload_conf();
```

### Step 2 — Confirm the Slot is Inactive (Safe to Drop)

```sql
SELECT slot_name, active, active_pid
FROM pg_replication_slots
WHERE slot_name = 'analytics_slot';
```

- `active = false` and `active_pid = NULL` → safe to drop  
- `active = true` → a process is using it — do NOT drop; investigate what's connected

### Step 3 — THE FIX: Drop the Orphaned Slot

```sql
-- Option A: Drop the slot entirely (if logical subscriber is gone)
SELECT pg_drop_replication_slot('analytics_slot');

-- Option B: Re-enable the subscription (if subscriber exists but was paused)
-- Connect to the subscriber node:
psql -p 5435 -c "ALTER SUBSCRIPTION analytics_sub ENABLE;"
```

> **Option A** = slot is permanently abandoned (subscriber removed or lost)  
> **Option B** = subscriber still exists but the subscription was accidentally disabled

### Step 4 — Watch WAL Drain in Real Time

```bash
watch -n 1 'psql -c "
SELECT slot_name, wal_status,
  pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained
FROM pg_replication_slots;"'
```

**Short explanation:** This lets you see, once per second, whether retained WAL is dropping after the fix.

```bash
watch -n 1 'du -csh /data/primary/pg_wal'
```

**Short explanation:** This confirms the `pg_wal` directory is shrinking and disk pressure is going away.

After dropping: the `pg_wal/` directory should begin shrinking as PostgreSQL recycles old segments.

### Step 5 — Reclaim Space & Re-Baseline

```sql
-- Force a checkpoint to flush dirty pages and update pg_control:
CHECKPOINT;
```

```bash
# Take a fresh base backup immediately after recovery:
pg_basebackup -h localhost -U postgres -D /tmp/fresh_backup_$(date +%Y%m%d_%H%M) -Fp -Xs -P
```

---

## Phase 4 — RESOLVE: Stabilization & Verification

### Stage 4 = Stabilize

This stage is about making sure the system is not only “less broken,” but actually stable again.

Think of Stage 4 in three parts:

1. **System health verification**
  - Check disk usage is falling
  - Check `pg_wal` is shrinking
  - Check latency symptoms are improving

2. **Recovery chain verification**
  - Check replication is healthy again
  - Check archiving is working again
  - Confirm backup and recovery flow is trustworthy again

3. **Prevention guardrail**
  - Add a safety valve so one bad slot cannot fill the disk again
  - Main guardrail here = `max_slot_wal_keep_size`
  - Add active monitoring so the team sees WAL growth before it becomes a crisis

### Verify Disk is Recovering

```bash
df -h /data
du -sh /data/primary/pg_wal/
```

Expected: `pg_wal/` shrinking; disk usage falling below 80%.

### Verify Replication is Healthy Again

```sql
-- Streaming replica lag:
SELECT application_name, replay_lag, state
FROM pg_stat_replication;

-- All slot statuses:
SELECT slot_name, active, wal_status,
  pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots;
```

### Verify Archive is Working Again

```sql
SELECT last_archived_wal, last_archived_time, failed_count
FROM pg_stat_archiver;
```

- `failed_count` should stop increasing
- `last_archived_time` should be recent (within last few minutes)

### Resume Workload

```bash
docker start pg-workload
```

---

## Phase 5 — PREVENTION: Safety Valve & Monitoring

### Set a WAL Retention Limit Per Slot

Prevents any single broken slot from consuming unlimited disk:

```sql
ALTER SYSTEM SET max_slot_wal_keep_size = '5GB';
SELECT pg_reload_conf();
```

**Effect:** If a slot accumulates more than 5GB of WAL, PostgreSQL invalidates it (`wal_status = lost`) and recycles the segments — protecting disk over replication slot health.

**Beginner note:** This is a prevention safety valve. It does **not** fix a broken slot by itself, but it stops one slot from growing forever and filling the disk.

### Prevention = Guardrail + Active Monitoring

Good prevention in this scenario has two parts:

1. **Guardrail:** `max_slot_wal_keep_size`
  - Limits how much WAL one slot can retain
  - Protects disk space
  - If the slot crosses the limit, PostgreSQL can mark it as lost instead of filling the disk forever

2. **Active monitoring**
  - Watch inactive slots with large retained WAL
  - Watch archive failures
  - Watch `pg_wal` directory growth
  - Watch disk usage before it reaches critical levels

**Query to monitor inactive slots:**

```sql
SELECT
  slot_name,
  slot_type,
  active,
  wal_status,
  restart_lsn,
  pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots
WHERE NOT active
ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC;
```

**Short explanation:**
- `WHERE NOT active` = show only inactive slots
- `retained_wal` = how much WAL each inactive slot is keeping on disk
- Top rows are the most dangerous slots because they retain the most WAL

Simple idea:

> **Guardrail prevents unlimited damage. Monitoring gives early warning.**

### Monitoring Alerts to Add

These are the three main alerts to set for this scenario.

### Alert Set 1 — Inactive replication slot with WAL > 1GB

**Alert 1: Inactive slot holding > 1GB WAL**
```sql
SELECT slot_name, slot_type,
  pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots
WHERE NOT active
  AND pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) > 1073741824; -- 1GB
```

**Why this alert matters:**
- An inactive slot is not consuming WAL
- PostgreSQL must keep old WAL for that slot
- If retained WAL keeps growing, disk pressure can become a full outage

### Alert Set 2 — WAL archive falling behind

**Alert 2: WAL archiving falling behind**
```sql
SELECT
  (last_failed_time > last_archived_time) AS archive_failing,
  failed_count,
  now() - last_archived_time AS time_since_last_archive
FROM pg_stat_archiver;
```

**Why this alert matters:**
- If archiving fails, PITR becomes unsafe or incomplete
- If archiving fails during WAL buildup, disk can fill faster
- This is both a recovery risk and a capacity risk

### Alert Set 3 — `pg_wal/` directory growing beyond threshold

**Alert 3: pg_wal/ directory size threshold (shell/cron)**
```bash
WAL_SIZE=$(du -sm /data/primary/pg_wal/ | cut -f1)
if [ "$WAL_SIZE" -gt 5120 ]; then
  echo "CRITICAL: pg_wal exceeds 5GB (${WAL_SIZE} MB)"
fi
```

**Why this alert matters:**
- This is the direct disk-growth signal
- Even if you miss slot details, this catches WAL growth on disk
- It helps you respond before disk usage reaches dangerous levels like 90%+

---

## 🗺️ Incident Flow Summary

```
🚨 Alert: High Latency / Slow Queries
         ↓
Phase 1 — DETECT
  pg_stat_replication → replica lag spike
  pg_replication_slots → inactive slot with large retained_wal
  df -h → disk growing
         ↓
Phase 2 — DIAGNOSE
  watch pg_replication_slots → WAL flood confirmed
  pg_stat_archiver → archive failures = PITR broken
  Logs → "No space left on device" warnings
         ↓
Phase 3 — MITIGATE
  Stop workload / throttle I/O
  Confirm slot is inactive (safe to drop)
  pg_drop_replication_slot('analytics_slot')  ← THE FIX
  Watch pg_wal/ drain
         ↓
Phase 4 — RESOLVE
  Verify disk recovering
  Verify replication healthy
  Verify archive working
  Fresh pg_basebackup
  Resume workload
         ↓
Phase 5 — LEARN
  Set max_slot_wal_keep_size = '5GB'  ← Safety valve
  Add slot monitoring alerts
  Add archive health alerts
  Post-Incident Review
```

---

## ⚠️ Root Cause Summary

| Cause | Effect | Fix |
|-------|--------|-----|
| Orphaned replication slot (`analytics_slot`) | WAL cannot be recycled → disk fills | `pg_drop_replication_slot()` |
| Subscriber paused/disabled | Slot remains active but not consuming | `ALTER SUBSCRIPTION ... ENABLE` |
| No `max_slot_wal_keep_size` set | No safety valve — slot can grow to fill disk | `ALTER SYSTEM SET max_slot_wal_keep_size` |
| WAL archive destination full | Archive fails → PITR gap | Fix archive destination + re-archive |
| Disk fill → checkpoint stall | All writes wait → latency spikes | Reclaim space + `CHECKPOINT` |

---

## 📋 Quick Reference — Essential Commands

```sql
-- List all replication slots:
SELECT * FROM pg_replication_slots;

-- WAL retained by each slot:
SELECT slot_name,
  pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal,
  active, wal_status
FROM pg_replication_slots;

-- Drop orphaned slot:
SELECT pg_drop_replication_slot('slot_name');

-- Check replication lag:
SELECT application_name, replay_lag FROM pg_stat_replication;

-- Check archiver status:
SELECT * FROM pg_stat_archiver;

-- Force WAL switch (if needed):
SELECT pg_switch_wal();

-- Force checkpoint:
CHECKPOINT;

-- Set slot WAL limit (safety valve):
ALTER SYSTEM SET max_slot_wal_keep_size = '5GB';
SELECT pg_reload_conf();
```

```bash
# Check WAL directory size:
du -sh /data/primary/pg_wal/

# Count WAL segments:
ls /data/primary/pg_wal/ | wc -l

# Watch WAL directory size live:
watch -n 1 'du -csh /data/primary/pg_wal'

# Watch slot retention live:
watch -n 1 'psql -c "SELECT slot_name, wal_status,
pg_size_pretty(pg_wal_lsn_diff(
pg_current_wal_lsn(), restart_lsn))
AS retained
FROM pg_replication_slots;"'

# Watch disk usage:
watch -n 5 'df -h /data && du -sh /data/primary/pg_wal/'
```

### Beginner Command Notes

- `watch -n 1 '...'` → run the same command every 1 second so you can watch changes live
- `du -sh <path>` → show total size of a folder in a human-readable format like `MB` or `GB`
- `du -csh <path>` → same as above, but also prints a grand total line
- `psql -c "..."` → connect to PostgreSQL and run one SQL statement
- `pg_size_pretty(...)` → convert bytes into readable values like `42 MB`
- `pg_wal_lsn_diff(a, b)` → calculate how much WAL exists between two WAL positions
- `pg_current_wal_lsn()` → current WAL write position on the primary
- `restart_lsn` → the oldest WAL position PostgreSQL must keep for a slot

---

## 🔍 Key Concepts

| Term | Definition |
|------|-----------|
| **Replication Slot** | A named cursor that tracks how far a consumer (replica or subscriber) has replayed WAL. PostgreSQL won't recycle WAL before the slot's `restart_lsn`. |
| **Orphaned Slot** | A slot whose consumer (subscriber or standby) no longer exists or is disconnected, but the slot was never dropped. |
| **WAL Flood** | Unbounded accumulation of WAL segments in `pg_wal/` caused by an orphaned or lagging slot. |
| **max_slot_wal_keep_size** | Safety parameter: maximum WAL PostgreSQL will retain for any slot. If exceeded, slot is invalidated (`wal_status = lost`). |
| **pg_stat_archiver** | System view showing WAL archive health: last success, last failure, failure count. |
| **WAL Archive** | A directory/S3/GCS destination where WAL segments are copied for PITR. If archive fails, PITR recovery window has a gap. |
| **PITR** | Point-In-Time Recovery — restoring to any past moment using base backup + WAL archive. Broken if archive is incomplete. |

---

## 🧠 Beginner Note — Is Creating WAL Costly?

Short answer: **yes, but usually WAL retention is the bigger danger in this scenario.**

### What “WAL cost” means

When PostgreSQL changes data (`INSERT`, `UPDATE`, `DELETE`), it first records the change in **WAL**.

This has a few costs:

- **CPU cost** → PostgreSQL must build the WAL record
- **Disk write cost** → WAL must be written to disk
- **Flush/fsync cost** → commits may wait until WAL is safely flushed
- **Storage cost** → WAL files take disk space

### What is usually expensive?

- **Generating a normal amount of WAL** = expected overhead for safe writes
- **Flushing lots of WAL during heavy write traffic** = can increase latency
- **Retaining old WAL because of a stuck replication slot** = the real problem in Scenario 2

### Simple rule to remember

- **Reads** usually create little or no WAL
- **Writes** create WAL
- **More writes + more indexes + large transactions** = more WAL generated
- **Broken or inactive slot** = old WAL cannot be removed
- **Old WAL keeps growing** = disk pressure, checkpoint stalls, slow performance

### Scenario 2 takeaway

In this incident, the main issue is not just that PostgreSQL is creating WAL.

The main issue is:

1. WAL is being generated by normal write activity
2. A slot is not consuming it
3. PostgreSQL must keep old WAL files
4. `pg_wal` grows too large
5. Disk fills up and the database becomes slow

So the important lesson is:

> **Creating WAL is normal. Keeping too much WAL is dangerous.**

---

## ✅ Key Takeaways (Scenario 2)

1. **Slots are liabilities (if unmanaged)**
  - A replication slot protects data continuity, but it can also retain WAL indefinitely.
  - Any inactive or orphaned slot is an operational risk until it is fixed or removed.

2. **Understand the cascade effect**
  - Stuck slot → WAL buildup → disk pressure → checkpoint/fsync stress → query latency/timeouts.
  - One replication issue can quickly become a full performance incident.

3. **Crisis sequencing matters**
  - Correct order: contain → verify → execute critical fix → reclaim/repair.
  - Wrong sequencing (for example, restart first or drop without verification) can worsen impact.

4. **PITR integrity is part of incident success**
  - Recovery is not complete unless archive health is validated.
  - After archive gaps or failures, take a fresh base backup to re-establish trusted PITR capability.

5. **Essential safety valves must be configured**
  - `max_slot_wal_keep_size` limits slot-driven WAL retention.
  - Safety valves do not replace fixing root cause; they prevent unlimited damage.

6. **Process completeness over quick patching**
  - A true resolution includes: performance recovery, replication health, archiver health, backup baseline, and monitoring alerts.
  - If any link is skipped, the same incident can return.

---

## ⚠️ Common Pitfalls (and Safer Alternatives)

1. **Unverified deletion**
  - Pitfall: Dropping a replication slot before confirming whether it is truly inactive/orphaned.
  - Risk: Breaking a valid subscriber or replication path.
  - Safer move: Verify `active`, `active_pid`, and subscriber state before any `pg_drop_replication_slot()`.

2. **Panic restart**
  - Pitfall: Restarting PostgreSQL immediately when disk is critically high.
  - Risk: Lost time, repeated pressure after restart, and possible recovery stress under near-full disk.
  - Safer move: Contain load first, identify slot/archive cause, then apply targeted fix.

3. **Recovery-gap blind spot**
  - Pitfall: Declaring incident resolved without validating archive continuity and PITR readiness.
  - Risk: Hidden recovery gap; restore may fail when needed.
  - Safer move: Check `pg_stat_archiver`, ensure failures stop, and take a fresh base backup after repair.

4. **Symptom chasing**
  - Pitfall: Focusing only on slow queries/timeouts without investigating replication slots and WAL growth.
  - Risk: Temporary relief but recurring outage.
  - Safer move: Trace the chain: latency → WAL pressure → slot/archive root cause.

5. **Missing guardrails**
  - Pitfall: Running logical/streaming replication without slot-retention limits and alerts.
  - Risk: Single stuck slot can consume disk until outage.
  - Safer move: Set `max_slot_wal_keep_size` and enable active alerts for slot WAL, archiver health, and `pg_wal` size.

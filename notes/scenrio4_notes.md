## Scenario 4 Notes

### Incident Summary

- Issue: application delay
- Error observed: "server closed the connection unexpectedly"
- Error observed: "database system is in recovery mode"

### Initial Interpretation

- The database likely restarted or crashed and is replaying WAL.
- During recovery mode, write operations are unavailable and some client sessions fail.
- Application delay is expected until recovery completes or failover happens.

### OOM Kill — Key Causes

- Table/index bloat increasing memory pressure and inefficient execution.
- Autovacuum memory spikes.
- Too many connections (high backend memory footprint).
- Excessive `work_mem` / `maintenance_work_mem` settings.
- Parallel query memory multiplication across workers.
- Linux overcommit configuration issues.
- Insufficient or no swap.
- Query planner underestimation leading to heavy memory use.
- Extensions or PL languages allocating extra memory outside expected planner assumptions.

### Why This Causes "Recovery Mode" Errors

- When Linux OOM killer terminates the PostgreSQL postmaster or critical backend process,
  PostgreSQL performs crash recovery on restart.
- During this period, applications may see:
  - "server closed the connection unexpectedly"
  - "database system is in recovery mode"
- This usually means PostgreSQL is replaying WAL and trying to restore consistency.

### Deeper Explanation of Key Causes

1. Table/Index Bloat
	- Bloated tables/indexes increase I/O and memory needs for scans/sorts.
	- Queries take longer and may allocate more memory than expected.
	- Mechanism:
	  - More dead tuples/pages -> larger scans -> bigger sort/hash intermediates.
	  - Longer-running queries overlap more often, so concurrent memory demand rises.
	  - Autovacuum/reindex work also gets heavier, adding background memory pressure.
	  - Net effect: total memory consumption crosses host limit and Linux may trigger OOM kill.

2. Autovacuum Memory Spikes
	- Aggressive vacuum/analyze on large tables can consume significant memory.
	- Multiple autovacuum workers can create cumulative pressure.

3. Too Many Connections
	- Each backend uses baseline memory even when idle.
	- High connection count reduces available memory for active workloads.

4. High `work_mem` and `maintenance_work_mem`
	- `work_mem` can be used per sort/hash operation, not per query only.
	- `maintenance_work_mem` affects vacuum/index operations and can be large.

5. Parallel Query Multiplication
	- Parallel workers can multiply memory usage for one query plan.
	- Effective memory can grow quickly under concurrent parallel queries.

6. Linux Overcommit and Swap Issues
	- Overcommit settings may allow allocations that cannot be safely backed.
	- Little/no swap can trigger faster OOM kills during spikes.

7. Planner Underestimation
	- Bad statistics can choose memory-heavy plans unexpectedly.
	- Real runtime memory can exceed planned/assumed footprint.

8. Extension / PL Memory Usage
	- Some extensions or procedural code may allocate outside planner assumptions.
	- Memory growth may be less visible in simple SQL-only tuning.

### Quick Triage (First 10–15 Minutes)

1. Confirm OOM event at OS level
	- Check kernel logs (`dmesg`, `journalctl`) for "Out of memory" / kill entries.
2. Confirm PostgreSQL crash/restart timeline
	- Correlate PostgreSQL logs with app error timestamps.
3. Reduce pressure immediately
	- Limit new connections (pooler throttle / app-side backoff).
	- Cancel or pause heavy jobs (large reports, maintenance bursts).
4. Check recovery progress
	- Monitor if recovery is completing normally before forcing failover decisions.

### Stabilization Actions (After Immediate Triage)

- Connection control
  - Use connection pooling; reduce max active backend count.
- Memory guardrails
  - Revisit `work_mem`, `maintenance_work_mem`, and parallel settings.
- Autovacuum tuning
  - Tune worker count/cost/delay for large-table environments.
- Bloat management
  - Plan vacuum/reindex/repack windows to reduce long-term pressure.
- OS baseline
  - Review overcommit behavior and maintain safe swap strategy.
- Query quality
  - Refresh statistics and tune high-memory query patterns.

### Practical Learning Takeaway

- OOM is often a systems problem, not only a single bad query.
- Preventive controls = connection limits + sane memory settings + clean tables + monitored OS.
- If the DB enters recovery mode after connection drops, always check OOM evidence first.

### Silent Bloat Meltdown — First Response Checklist

1. Check dead tuple ratio for all user tables (find worst offenders first)

```sql
SELECT
		schemaname,
		relname,
		n_live_tup,
		n_dead_tup,
		ROUND((n_dead_tup::numeric / NULLIF(n_live_tup + n_dead_tup, 0)) * 100, 2) AS dead_tuple_pct,
		last_autovacuum,
		last_autoanalyze
FROM pg_stat_user_tables
ORDER BY dead_tuple_pct DESC NULLS LAST, n_dead_tup DESC;
```

2. Check global autovacuum settings first (cluster-level defaults)

```sql
SHOW autovacuum;
SHOW autovacuum_max_workers;
SHOW autovacuum_naptime;
SHOW autovacuum_vacuum_scale_factor;
SHOW autovacuum_analyze_scale_factor;
SHOW autovacuum_vacuum_threshold;
SHOW autovacuum_analyze_threshold;
SHOW autovacuum_work_mem;
```

3. Check table-level autovacuum overrides on affected tables

```sql
SELECT
		n.nspname AS schema_name,
		c.relname AS table_name,
		c.reloptions
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
	AND n.nspname NOT IN ('pg_catalog', 'information_schema')
	AND c.reloptions IS NOT NULL
ORDER BY n.nspname, c.relname;
```

- Fast interpretation tip:
	- High dead tuple % + stale `last_autovacuum` + restrictive table-level overrides = high bloat risk.

### Recovery Procedure Flowchart

```text
Start
	|
	v
Observe symptoms
	- app delay / timeout
	- server closed connection unexpectedly
	- database system is in recovery mode
	|
	v
Check OS + PostgreSQL logs timeline
	|
	v
Is OOM evidence present?
	|-- No --> continue normal DB diagnostics (locks, network, storage)
	|
	|-- Yes --> bloat/autovacuum diagnostics
							 |
							 v
			Measure dead tuples + table bloat
							 |
							 v
			Validate autovacuum state
			- global parameters
			- table-level overrides
							 |
							 v
			Analyze plan + stats on hot queries/tables
			- stale stats?
			- hash/sort/parallel memory pressure?
							 |
							 v
			Confirm 2-stage cascade model
							 |
							 v
			Stabilize (lower memory pressure + re-enable/tune autovacuum)
							 |
							 v
			Vacuum affected tables (non-FULL first) + verify
							 |
							 v
			Final validation + prevention actions
```

### Diagnostic Approach (Best Practice Sequence)

1. Observe symptoms
	 - Application side: high latency, retries, dropped connections.
	 - Database side: recovery mode messages, restart evidence.

2. Measure bloat and autovacuum state
	 - Check dead tuple ratios for all user tables.
	 - Confirm global autovacuum settings are active and sensible.
	 - Check table-level autovacuum overrides on critical tables.

3. Analysis: query plans and statistics
	 - Use `EXPLAIN (ANALYZE, BUFFERS)` for top heavy queries.
	 - Verify if stale stats (`n_mod_since_analyze`, old analyze times) caused bad plans.
	 - Look for memory-heavy operators: hash joins, large sorts, parallel workers.

4. Confirm the 2-stage cascade
	 - Stage A (Initial Failure): table bloat build-up + weak/disabled autovacuum + stale stats.
	 - Stage B (Critical Failure): memory spike -> Linux OOM kill -> PostgreSQL crash/recovery mode.

### Best Practices During Recovery

- Stabilize first, optimize second.
	- Reduce connection pressure and memory amplification before deep tuning.
- Apply safe runtime controls quickly.
	- Tune `work_mem`, `autovacuum_max_workers`, `autovacuum_vacuum_cost_delay`, and connection limits.
- Remove bad table-level overrides.
	- Reset per-table `autovacuum_enabled` overrides on affected large tables.
- Prefer `VACUUM` (not `VACUUM FULL`) during online recovery window.
	- Reclaim dead tuples safely without heavy table lock.
- Verify and document.
	- Re-run bloat checks, confirm autovacuum activity, and capture incident timeline.

### 2-Stage Cascade Model (Memory Aid)

- Stage A: Silent table bloat build-up
	- Dead tuples grow, stats become stale, query costs drift upward.
- Stage B: Critical memory collapse
	- Query/autovacuum/parallel memory overlaps -> OOM kill -> crash recovery -> app impact.

### Best Practices (Operational Discipline)

- Smart memory allocation
	- Set realistic `work_mem`, `maintenance_work_mem`, and parallel worker limits.
	- Budget memory for concurrency, not single-query peak only.

- Autovacuum discipline
	- Keep autovacuum enabled and tuned for workload size.
	- Avoid disabling autovacuum at table level except short, controlled windows.

- Proactive discipline
	- Review high-churn tables regularly for dead tuple growth.
	- Run periodic plan/statistics health checks on top queries.

- Proactive monitoring
	- Alert on dead tuple ratio, autovacuum lag, OOM events, and connection saturation.
	- Track trend lines, not only point-in-time spikes.

- Stabilize first
	- In incidents, reduce pressure first (connections + memory), then optimize.

- Efficient space reclamation
	- Prefer low-lock online reclamation tools like `pg_repack` when appropriate.
	- Use `VACUUM FULL` only with strict maintenance windows due to locking impact.


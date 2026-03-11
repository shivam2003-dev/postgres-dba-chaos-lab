## Scenario 3 Notes

### Training Context

- Training: PGConf Training
- Session: A Disastrous Day in the Life of a PostgreSQL DBA
- Focus: PostgreSQL Ransomware Simulation & PITR Recovery
- Scenario Name: OMG - I am under attack

### Incident Story (Simulation)

- Ransomware attack happens during the holiday season when the DBA is on leave.
- Attack is detected after return, while trying to access database tables.
- Reported symptoms:
	- Data issue: unable to access tables
	- Error: "could not open the file"

### Learning Objectives (Beginner Friendly)

- Blast radius
	- Understand how far the damage can spread (one DB, replica, full cluster, backups).
- Network isolation
	- Immediately isolate affected database systems from the network to stop further spread.
- RTO vs RPO
	- RTO (Recovery Time Objective): how fast service must come back.
	- RPO (Recovery Point Objective): how much data loss is acceptable (time window).
- PITR using pgBackRest
	- Practice Point-in-Time Recovery to restore to a safe timestamp before encryption/corruption.
- Stabilization framework
	- Follow a clear sequence: contain -> assess -> recover -> validate -> harden.

### First Response Steps

1. Contain immediately
	 - Remove DB access at network level to limit blast radius.
	 - Freeze/stop replication to avoid propagating bad data to replicas.
2. Preserve evidence
	 - Record exact error messages, affected databases, and first seen time.
	 - Keep logs and system timeline for root-cause analysis.
3. Assess scope
	 - Identify what is impacted: primary only, replicas, WAL archive, backups.
	 - Confirm last known good backup and restore point availability.

### Recovery Plan (PITR with pgBackRest)

1. Choose target recovery time
	 - Pick a timestamp just before the attack impact window.
2. Prepare clean restore environment
	 - Prefer restoring to clean/new host first for validation.
3. Run pgBackRest restore
	 - Restore full backup and replay WAL up to target time.
4. Validate restored data
	 - Check critical tables, row counts, and business transactions.
5. Controlled cutover
	 - Bring application traffic back only after validation checks pass.

### Stabilization Framework (After Restore)

- Security hardening
	- Rotate passwords/keys and review access rules.
- Reliability checks
	- Re-enable replication carefully and confirm lag/health.
- Monitoring
	- Add alerts for file access errors, replication anomalies, and backup failures.
- Readiness
	- Update runbook and conduct tabletop/drill regularly.

### Quick Memory Tips

- First priority in ransomware event: stop spread, then recover.
- Backups are useful only if restore is tested.
- Always define RTO/RPO before incident day.

### Top 5 Priority Tasks

1. Isolate the network
	- Disconnect/segment affected database systems to contain spread.
2. Do not pay ransom
	- Follow incident response and legal/compliance process instead.
3. Freeze all replicas
	- Stop replication immediately to prevent corruption propagation.
4. Preserve evidence
	- Keep logs, timelines, and impacted artifacts for forensics.
5. Notify stakeholders
	- Inform leadership, security, legal, and application owners.

### Which Path to Take? (Recommended)

- Preferred path in this scenario: **Promote Replica2 first** (if it is clean and delayed enough to avoid attack WAL).
	- Why: fastest service recovery (better RTO) with lower risk during active incident.
- Second path: **PITR using pgBackRest** on clean infrastructure when Replica2 is not clean.
	- Why: precise recovery to a safe timestamp (better control of RPO).
- Last path: **Salvage primary** only after business service is restored.
	- Why: compromised primary should be treated as untrusted during incident.

### Simple Decision Rule

1. If Replica2 has clean data -> promote Replica2.
2. If all replicas are affected -> run PITR from pgBackRest backups/WAL.
3. Keep original primary isolated for forensics, not immediate production.

### RTO vs RPO vs Risk Profile (All Three Paths)

| Recovery Path | RTO (how fast) | RPO (data loss window) | Risk Profile |
|---|---|---|---|
| Promote Replica2 | Low (fastest) | Low to Medium (depends on replay delay and last applied WAL) | Medium: fast recovery, but only safe if replica is verified clean |
| PITR with pgBackRest | Medium to High (restore + replay time) | Low (can target pre-attack timestamp) | Low to Medium: controlled recovery, but operationally heavier |
| Salvage Primary | Variable, often High | Unknown to High | High: compromised system, integrity/trust concerns |

- Practical takeaway:
	- Best RTO: Promote Replica2 (when clean).
	- Best RPO control: PITR with pgBackRest.
	- Highest risk: Salvage primary during active incident.

recommandation do option A and B in parallel ; dont attempt opetion 3 

### Junior Admin Panic Response vs Senior Admin Response

- What junior admin did (panic action):
	- Ran `pg_resetwal` on the damaged primary to force PostgreSQL to start.

- Why this is dangerous in this scenario:
	- `pg_resetwal` rewrites WAL control metadata and can break recovery chain continuity.
	- It may start the server, but data consistency is not guaranteed.
	- It can make PITR/forensics harder because timeline and WAL history become unreliable.

- Likely result after panic action:
	- Instance may come up, but with hidden corruption risk.
	- Replica/WAL relationships may become invalid.
	- Trust in primary data drops; cannot treat it as safe production source.

- What senior admin should do instead:
	1. Keep compromised primary isolated (no client traffic).
	2. Do not use `pg_resetwal` as first incident response.
	3. Freeze replay on replicas and identify the cleanest recovery source.
	4. Recover service via clean delayed replica promotion OR PITR with pgBackRest.
	5. Validate critical data before cutover.
	6. Keep primary for evidence and offline analysis.

- Rule of thumb:
	- `pg_resetwal` is a last-resort lab/emergency tool, not a ransomware recovery strategy.

### Prevention Cheat Sheet

#### 1) Access Hardening

- Rotate SSH keys regularly.
- Disable interactive login where possible.
- Enforce MFA for all privileged access.
- Apply least privilege for DB roles, OS users, and automation accounts.

#### 2) Backup Resilience

- Follow 3-2-1 rule:
	- 3 copies of data
	- 2 different storage types
	- 1 copy offsite/offline
- Use immutable backups (cannot be modified/deleted during retention window).
- Encrypt backups at rest and in transit.
- Run weekly restore fire drills.

#### 3) Detection and Monitoring

- Monitor suspicious file extensions and mass file rename patterns.
- Enable data checksums and monitor checksum errors.
- Create alerts for dangerous commands and unusual admin actions.
- Track key metrics:
	- replication lag
	- WAL generation spikes
	- failed login attempts
	- backup success/failure
- Enable intentional lag on at least one replica for rollback safety.

#### 4) Operational Discipline

- Review and update runbooks quarterly.
- Perform ransomware drills regularly (tabletop + technical recovery drill).
- Ensure audit logs are enabled, centralized, and retained for investigations.

#### 5) Quick Daily/Weekly Checklist

- Daily: backup status, replication health, failed logins, critical alerts.
- Weekly: restore test, key rotation review, dangerous-command alert review.
- Quarterly: full incident simulation and runbook refresh.

### What You Should Walk Away With

- Containment first, always.
	- Isolate network paths and freeze replication before any risky action.
- Replication lag is a defense, not only a performance metric.
	- Intentional lag can preserve a clean recovery source.
- Precision PITR is a core survival skill.
	- Restore to exact pre-attack time using pgBackRest + WAL.
- Parallel recovery reduces downtime.
	- Validate clean delayed replica and prepare PITR path in parallel.
- `pg_resetwal` is a trap during ransomware response.
	- It may boot the instance but can break trust, timeline, and recovery certainty.
- Immutable backups are non-negotiable.
	- Backups must be protected from tampering/deletion and tested regularly.

### Defense Layers

#### 1) Network Security

- Restrict DB ports to allowlisted app/admin networks only.
- Segment production DB network from user/workstation networks.
- Block direct internet exposure for database hosts.
- Use firewall rules and security groups with default-deny model.

#### 2) AuthN and AuthZ

- Enforce strong authentication (MFA + short-lived credentials where possible).
- Disable shared accounts; use individual, auditable identities.
- Apply least privilege and role-based access control.
- Separate duties for DBA, app owner, backup operator, and security team.

#### 3) Encryption (At Rest + In Transit)

- Encrypt disks/volumes and backup storage at rest.
- Enforce TLS for client-to-DB and replication traffic.
- Protect and rotate encryption keys with strict access control.

#### 4) Logging and Auditing

- Enable PostgreSQL audit logging for DDL/DCL and privileged operations.
- Forward logs to centralized, tamper-resistant storage.
- Alert on suspicious patterns: mass updates, drops, key role changes, failed logins.
- Keep retention policy long enough for incident investigations.

#### 5) Extension and Attack Surface Control

- Install only required PostgreSQL extensions.
- Restrict who can create/enable extensions.
- Review extension versions and patch regularly.
- Remove unused services/packages from DB hosts to reduce attack surface.

#### 6) Install and Operations Hardening

- Harden OS baseline (minimal packages, secure SSH config, patch cadence).
- Disable unnecessary interactive shell access on database hosts.
- Use configuration management and change approvals for critical settings.
- Validate backups/restores and run ransomware drills on a schedule.










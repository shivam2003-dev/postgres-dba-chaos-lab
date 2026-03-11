# Readiness Checklist

## Switch to the `postgres` User

```bash
sudo su - postgres
```

## Verify Replication State

Run the following commands to confirm which nodes are primary or replicas and to inspect replication slots.

```bash
psql -p 5432 -c "select pg_is_in_recovery();"
psql -p 5433 -c "select pg_is_in_recovery();"
psql -p 5434 -c "select pg_is_in_recovery();"
psql -p 5432 -c "select slot_name, slot_type from pg_replication_slots;"
```

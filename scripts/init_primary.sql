DROP TABLE IF EXISTs events;
DROP TABLE IF EXISTS metrics;

CREATE TABLE events (
    id         SERIAL,
    event_type TEXT,
    payload    JSONB,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE metrics (
    id         SERIAL,
    host       TEXT,
    metric     TEXT,
    value      FLOAT,
    recorded_at TIMESTAMPTZ DEFAULT NOW()
);

-- create publication for the logical replication
CREATE PUBLICATION analytics_pub FOR ALL TABLES;

SELECT pg_create_physical_replication_slot('replica1_slot');
SELECT pg_create_physical_replication_slot('replica2_slot');
CREATE USER  replicator REPLICATION PASSWORD 'repl_pass123';
CREATE USER  logical_usr REPLICATION PASSWORD 'logical_pass123';
GRANT SELECT ON ALL TABLES IN SCHEMA public TO logical_usr;
GRANT CONNECT on DATABASE postgres TO logical_usr;

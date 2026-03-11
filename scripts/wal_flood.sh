DB='postgres'
USER='postgres'
BATCH=200
COUNTER=0

echo "[WAL FLOOD] Starting... Press Ctrl+C to stop."
trap 'echo "[WAL FLOOD] Stopped after $COUNTER batches."; exit 0' INT
psql -p 5435 -c "alter subscription analytics_sub disable;"
while true; do
    psql -U $USER -d $DB -q -c "
        INSERT INTO events (event_type, payload)
        SELECT 'flood_test',
               json_build_object('batch', $COUNTER, 'row', g, 'ts', now())
        FROM generate_series(1, $BATCH) g;

        INSERT INTO metrics (host, metric, value, recorded_at)
        SELECT 'flood-host-' || (random()*10)::int,
               'iops',
               random() * 1000,
               NOW()
        FROM generate_series(1, $BATCH) g;
    "
    COUNTER=$((COUNTER + 1))
    echo -ne "[WAL FLOOD] Batch $COUNTER done\r"
done

#!/bin/bash
psql -p 5435 -c "alter subscription analytics_sub disable;"
for i in $(seq 1 5000); do
  psql -U postgres  -c "
    INSERT INTO events (event_type, payload)
    VALUES ('page_view', json_build_object('user', $i, 'page', '/home'));
    INSERT INTO metrics (host, metric, value)
    VALUES ('web-01', 'cpu_pct', random()*100);
  " > /dev/null
  sleep 0.1
done

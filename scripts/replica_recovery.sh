#!/bin/bash

# Script: replica_point_in_time_recovery.sh
# Purpose: Configure replica2 for Point-In-Time Recovery using pgBackRest

REPLICA_DATA="/data/replica2"
TIME_FILE="/data/primary/.time.txt"
CONF_FILE="/data/replica2/postgresql.auto.conf"
PGBACKREST_CONF="/etc/pgbackrest/pgbackrest.conf"

# Update pgBackRest path
sudo sed -i 's|^pg1-path=.*|pg1-path=/data/replica2|' $PGBACKREST_CONF

# Stop replica
#sudo systemctl stop postgresql@18-replica2

# Comment only recovery_min_apply_delay parameter
#sudo sed -i 's/^primary_conninfo/#primary_conninfo/' $CONF_FILE
#sudo sed -i 's/^primary_slot_name/#primary_slot_name/' $CONF_FILE
sudo sed -i 's/^recovery_min_apply_delay/#recovery_min_apply_delay/' $CONF_FILE

# Read recovery time
RECOVERY_TIME=$(cat $TIME_FILE)

# Append new recovery parameters
sudo bash -c "cat >> $CONF_FILE <<EOF

# Added by replica_point_in_time_recovery.sh
restore_command = 'pgbackrest --stanza=primary archive-get %f \"%p\"'
recovery_target_time = '$RECOVERY_TIME'

EOF"

# Create standby.signal
#sudo touch $REPLICA_DATA/standby.signal
#sudo chown postgres:postgres $REPLICA_DATA/standby.signal
#sudo chmod 600 $REPLICA_DATA/standby.signal

# Start replica
sudo systemctl restart postgresql@18-replica2

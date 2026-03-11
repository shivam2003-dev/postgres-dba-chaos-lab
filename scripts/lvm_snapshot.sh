#!/bin/bash

set -o pipefail

VG_PATH="/dev/vg_data/lv_data"
VG_NAME="vg_data"
DATA_MOUNT="/data"

STOP_SCRIPT="/var/lib/postgresql/scripts/stop_services.sh"
START_SCRIPT="/var/lib/postgresql/scripts/start_services.sh"

log() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

error_exit() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1"
    exit 1
}

show_help() {
cat << EOF
LVM Snapshot Management Script

Usage:
  $0 <action> <snapshot_name>

Actions:
  create <snapshot_name>   Create an LVM snapshot
  merge  <snapshot_name>   Merge (restore) the snapshot

Options:
  -h, --help               Show this help message

Examples:
  $0 create lv_data_snap
  $0 merge lv_data_snap

Description:
  This script safely stops PostgreSQL services, performs LVM snapshot
  operations on /dev/vg_data/lv_data, and restarts services.
EOF
}

run_cmd() {
    "$@"
    if [ $? -ne 0 ]; then
        error_exit "Command failed: $*"
    fi
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        error_exit "This script must be run as root."
    fi
}

check_snapshot_exists() {
    lvdisplay "$1" &>/dev/null
}

create_snapshot() {

    SNAPSHOT_PATH="/dev/$VG_NAME/$SNAPSHOT_NAME"

    if check_snapshot_exists "$SNAPSHOT_PATH"; then
        error_exit "Snapshot $SNAPSHOT_NAME already exists."
    fi

    log "Stopping services..."
    run_cmd bash "$STOP_SCRIPT"

    log "Creating snapshot $SNAPSHOT_NAME..."
    run_cmd lvcreate -s -L 1.8G -n "$SNAPSHOT_NAME" "$VG_PATH"

    log "Displaying logical volumes..."
    run_cmd lvdisplay

    log "Starting services..."
    run_cmd bash "$START_SCRIPT"

    log "Snapshot created successfully."
}

merge_snapshot() {

    SNAPSHOT_PATH="/dev/$VG_NAME/$SNAPSHOT_NAME"

    if ! check_snapshot_exists "$SNAPSHOT_PATH"; then
        error_exit "Snapshot $SNAPSHOT_NAME does not exist."
    fi

    log "Stopping services..."
    run_cmd bash "$STOP_SCRIPT"

    log "Merging snapshot..."
    run_cmd lvconvert --merge "$SNAPSHOT_PATH"

    log "Unmounting $DATA_MOUNT..."
    run_cmd umount "$DATA_MOUNT"

    log "Deactivating logical volume..."
    run_cmd lvchange -a n "$VG_PATH"

    log "Reactivating logical volume..."
    run_cmd lvchange -a y "$VG_PATH"

    log "Mounting $DATA_MOUNT..."
    run_cmd mount "$DATA_MOUNT"

    log "Starting services..."
    run_cmd bash "$START_SCRIPT"

    log "Snapshot merge completed successfully."
}

ACTION=$1
SNAPSHOT_NAME=$2

if [[ "$ACTION" == "-h" || "$ACTION" == "--help" ]]; then
    show_help
    exit 0
fi

if [[ -z "$ACTION" || -z "$SNAPSHOT_NAME" ]]; then
    show_help
    exit 1
fi

check_root

case "$ACTION" in
    create)
        create_snapshot
        ;;
    merge)
        merge_snapshot
        ;;
    *)
        error_exit "Invalid action: $ACTION"
        ;;
esac

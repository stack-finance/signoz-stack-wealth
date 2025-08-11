#!/bin/bash

set -e

BACKUP_DIR="$PWD"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RETENTION_DAYS=30  # keep backups for 30 days

CLICKHOUSE_BACKUP="signoz_clickhouse_data_backup_$TIMESTAMP.tar.gz"
SQLITE_BACKUP="signoz_sqlite_data_backup_$TIMESTAMP.tar.gz"
ZOOKEEPER_BACKUP="signoz_zookeeper_data_backup_$TIMESTAMP.tar.gz"

# Function to upload and delete local file
upload_and_clean() {
  local file="$1"
  local s3path="$2"

  echo "‚òÅÔ∏è Uploading $file to $s3path"
  if aws s3 cp "$file" "$s3path"; then
    echo "Ì∑ëÔ∏è Deleting local file $file after successful upload"
    rm -f "$file"
  else
    echo "‚ùå Upload failed for $file. Deleting local copy anyway"
    rm -f "$file"
  fi
}

# --- CLICKHOUSE BACKUP (with safe stop/restart) ---
CONTAINER_NAME="signoz-clickhouse"

echo "Ì≥¶ Preparing ClickHouse for backup..."
if ! docker stop "$CONTAINER_NAME" >/dev/null 2>&1; then
  echo "‚ö†Ô∏è Graceful stop failed, checking PID..."
  PID=$(sudo docker inspect -f '{{.State.Pid}}' "$CONTAINER_NAME" 2>/dev/null || echo "")
  if [[ -n "$PID" && "$PID" != "0" ]]; then
    echo "‚ö†Ô∏è Force killing PID $PID..."
    sudo kill -9 "$PID" || true
  fi
fi

# Wait for container to actually stop
echo "‚è≥ Waiting for $CONTAINER_NAME to stop..."
for i in {1..10}; do
  PID=$(sudo docker inspect -f '{{.State.Pid}}' "$CONTAINER_NAME" 2>/dev/null || echo "0")
  if [[ "$PID" == "0" ]]; then
    echo "‚úÖ $CONTAINER_NAME stopped."
    break
  fi
  sleep 2
done

# Perform backup
echo "Ì≥¶ Backing up ClickHouse..."
docker run --rm \
  -v signoz-clickhouse:/data \
  -v "$BACKUP_DIR":/backup \
  ubuntu \
  bash -c "apt update -qq && apt install -y tar > /dev/null && tar czf /backup/$CLICKHOUSE_BACKUP -C /data ."

upload_and_clean "$BACKUP_DIR/$CLICKHOUSE_BACKUP" "s3://signoz-data-dump/clickhouse/"

# Restart ClickHouse
echo "Ì¥Ñ Restarting ClickHouse container..."
docker start "$CONTAINER_NAME"

# --- SQLITE BACKUP ---
echo "Ì≥¶ Backing up SQLite..."
docker run --rm \
  -v signoz-sqlite:/data \
  -v "$BACKUP_DIR":/backup \
  alpine \
  tar czf /backup/$SQLITE_BACKUP -C /data .

upload_and_clean "$BACKUP_DIR/$SQLITE_BACKUP" "s3://signoz-data-dump/sqlite/"

# --- ZOOKEEPER BACKUP ---
echo "Ì≥¶ Backing up Zookeeper..."
docker run --rm \
  -v signoz-zookeeper-1:/data \
  -v "$BACKUP_DIR":/backup \
  alpine \
  tar czf /backup/$ZOOKEEPER_BACKUP -C /data .

upload_and_clean "$BACKUP_DIR/$ZOOKEEPER_BACKUP" "s3://signoz-data-dump/zookeeper/"

# --- CLEAN OLD S3 BACKUPS ---
echo "Ì∑π Cleaning up S3 backups older than $RETENTION_DAYS days..."
cutoff_epoch=$(date -d "$RETENTION_DAYS days ago" +%s)

clean_old_backups() {
  local bucket_path="$1"
  aws s3 ls "$bucket_path" | while read -r line; do
    file_date=$(echo "$line" | awk '{print $1}')
    file_name=$(echo "$line" | awk '{print $4}')
    file_epoch=$(date -d "$file_date" +%s)
    if [ "$file_epoch" -lt "$cutoff_epoch" ] && [ -n "$file_name" ]; then
      echo "Ì∑ëÔ∏è Deleting old backup: $bucket_path$file_name"
      aws s3 rm "$bucket_path$file_name"
    fi
  done
}

clean_old_backups "s3://signoz-data-dump/clickhouse/"
clean_old_backups "s3://signoz-data-dump/sqlite/"
clean_old_backups "s3://signoz-data-dump/zookeeper/"

echo "‚úÖ Backup and cleanup completed at $(date)"

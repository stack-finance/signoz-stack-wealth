#!/bin/bash

set -e

BACKUP_DIR="$PWD"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RETENTION_DAYS=30  # updated to 30 days

CLICKHOUSE_BACKUP="signoz_clickhouse_data_backup_$TIMESTAMP.tar.gz"
SQLITE_BACKUP="signoz_sqlite_data_backup_$TIMESTAMP.tar.gz"
ZOOKEEPER_BACKUP="signoz_zookeeper_data_backup_$TIMESTAMP.tar.gz"

# Function to upload and delete local file
upload_and_clean() {
  local file="$1"
  local s3path="$2"

  echo "☁️ Uploading $file to $s3path"
  if aws s3 cp "$file" "$s3path"; then
    echo "🗑️ Deleting local file $file after successful upload"
    rm -f "$file"
  else
    echo "❌ Upload failed for $file. Deleting local copy anyway"
    rm -f "$file"
  fi
}

echo "📦 Backing up ClickHouse..."
docker run --rm \
  -v signoz-clickhouse:/data \
  -v "$BACKUP_DIR":/backup \
  ubuntu \
  bash -c "apt update -qq && apt install -y tar > /dev/null && tar czf /backup/$CLICKHOUSE_BACKUP --ignore-failed-read -C /data ."

upload_and_clean "$BACKUP_DIR/$CLICKHOUSE_BACKUP" "s3://signoz-data-dump/clickhouse/"

echo "📦 Backing up SQLite..."
docker run --rm \
  -v signoz-sqlite:/data \
  -v "$BACKUP_DIR":/backup \
  alpine \
  tar czf /backup/$SQLITE_BACKUP -C /data .

upload_and_clean "$BACKUP_DIR/$SQLITE_BACKUP" "s3://signoz-data-dump/sqlite/"

echo "📦 Backing up Zookeeper..."
docker run --rm \
  -v signoz-zookeeper-1:/data \
  -v "$BACKUP_DIR":/backup \
  alpine \
  tar czf /backup/$ZOOKEEPER_BACKUP -C /data .

upload_and_clean "$BACKUP_DIR/$ZOOKEEPER_BACKUP" "s3://signoz-data-dump/zookeeper/"

echo "🧹 Cleaning up S3 backups older than $RETENTION_DAYS days..."

cutoff_epoch=$(date -d "$RETENTION_DAYS days ago" +%s)

clean_old_backups() {
  local bucket_path="$1"
  aws s3 ls "$bucket_path" | while read -r line; do
    file_date=$(echo "$line" | awk '{print $1}')
    file_name=$(echo "$line" | awk '{print $4}')
    file_epoch=$(date -d "$file_date" +%s)
    if [ "$file_epoch" -lt "$cutoff_epoch" ]; then
      echo "🗑️ Deleting old backup: $bucket_path$file_name"
      aws s3 rm "$bucket_path$file_name"
    fi
  done
}

clean_old_backups "s3://signoz-data-dump/clickhouse/"
clean_old_backups "s3://signoz-data-dump/sqlite/"
clean_old_backups "s3://signoz-data-dump/zookeeper/"

echo "✅ Backup and cleanup completed at $(date)"

#!/bin/bash

set -e

BACKUP_DIR="$PWD"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RETENTION_DAYS=30

CLICKHOUSE_BACKUP="signoz_clickhouse_data_backup_$TIMESTAMP.tar.gz"
SQLITE_BACKUP="signoz_sqlite_data_backup_$TIMESTAMP.tar.gz"
ZOOKEEPER_BACKUP="signoz_zookeeper_data_backup_$TIMESTAMP.tar.gz"

echo "📦 Backing up ClickHouse..."
docker run --rm \
  -v signoz-clickhouse:/data \
  -v "$BACKUP_DIR":/backup \
  ubuntu \
  bash -c "apt update -qq && apt install -y tar > /dev/null && tar czf /backup/$CLICKHOUSE_BACKUP --ignore-failed-read -C /data ."

echo "📦 Backing up SQLite..."
docker run --rm \
  -v signoz-sqlite:/data \
  -v "$BACKUP_DIR":/backup \
  alpine \
  tar czf /backup/$SQLITE_BACKUP -C /data .

echo "📦 Backing up Zookeeper..."
docker run --rm \
  -v signoz-zookeeper-1:/data \
  -v "$BACKUP_DIR":/backup \
  alpine \
  tar czf /backup/$ZOOKEEPER_BACKUP -C /data .

echo "☁️ Uploading backups to S3..."
aws s3 cp "$BACKUP_DIR/$CLICKHOUSE_BACKUP" s3://signoz-data-dump/clickhouse/
aws s3 cp "$BACKUP_DIR/$SQLITE_BACKUP" s3://signoz-data-dump/sqlite/
aws s3 cp "$BACKUP_DIR/$ZOOKEEPER_BACKUP" s3://signoz-data-dump/zookeeper/

echo "🧹 Cleaning up local backups older than $RETENTION_DAYS days..."
find "$BACKUP_DIR" -type f -name 'signoz_*_backup_*.tar.gz' -mtime +$RETENTION_DAYS -exec rm -f {} \;

echo "🧹 Cleaning up S3 backups older than $RETENTION_DAYS days..."
# ClickHouse
aws s3 ls s3://signoz-data-dump/clickhouse/ | while read -r line; do
  file_date=$(echo $line | awk '{print $1}')
  file_name=$(echo $line | awk '{print $4}')
  file_epoch=$(date -d "$file_date" +%s)
  cutoff_epoch=$(date -d "$RETENTION_DAYS days ago" +%s)
  if [ "$file_epoch" -lt "$cutoff_epoch" ]; then
    echo "Deleting s3://signoz-data-dump/clickhouse/$file_name"
    aws s3 rm "s3://signoz-data-dump/clickhouse/$file_name"
  fi
done

# Repeat for SQLite
aws s3 ls s3://signoz-data-dump/sqlite/ | while read -r line; do
  file_date=$(echo $line | awk '{print $1}')
  file_name=$(echo $line | awk '{print $4}')
  file_epoch=$(date -d "$file_date" +%s)
  cutoff_epoch=$(date -d "$RETENTION_DAYS days ago" +%s)
  if [ "$file_epoch" -lt "$cutoff_epoch" ]; then
    echo "Deleting s3://signoz-data-dump/sqlite/$file_name"
    aws s3 rm "s3://signoz-data-dump/sqlite/$file_name"
  fi
done

# Repeat for Zookeeper
aws s3 ls s3://signoz-data-dump/zookeeper/ | while read -r line; do
  file_date=$(echo $line | awk '{print $1}')
  file_name=$(echo $line | awk '{print $4}')
  file_epoch=$(date -d "$file_date" +%s)
  cutoff_epoch=$(date -d "$RETENTION_DAYS days ago" +%s)
  if [ "$file_epoch" -lt "$cutoff_epoch" ]; then
    echo "Deleting s3://signoz-data-dump/zookeeper/$file_name"
    aws s3 rm "s3://signoz-data-dump/zookeeper/$file_name"
  fi
done

echo "✅ Backup and cleanup completed at $(date)"

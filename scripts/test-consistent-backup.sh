#!/usr/bin/env bash
set -Eeuo pipefail

export PATH="/usr/bin:/bin:/mingw64/bin:/cmd:${PATH:-}"

# 模拟运行中的 CPA 与 Manager，验证一致性快照的停机和恢复顺序。
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=cpa-cpam-manager.sh
NO_COLOR=1 source "$ROOT_DIR/cpa-cpam-manager.sh"

if [ -n "${PYTHON_BIN:-}" ] && "$PYTHON_BIN" -c 'import sqlite3' >/dev/null 2>&1; then
  :
elif python3 -c 'import sqlite3' >/dev/null 2>&1; then
  PYTHON_BIN=python3
elif python -c 'import sqlite3' >/dev/null 2>&1; then
  PYTHON_BIN=python
else
  PYTHON_BIN=""
fi
export PYTHON_BIN

TEMP_DIR="$(mktemp -d)"
TRACE_FILE="$TEMP_DIR/docker.trace"
trap 'rm -rf "$TEMP_DIR"' EXIT

mkdir -p "$TEMP_DIR/install/cpa-manager-data" "$TEMP_DIR/install/auths" "$TEMP_DIR/install/logs"
printf 'sqlite-test\n' > "$TEMP_DIR/install/cpa-manager-data/usage.sqlite"
printf 'auth-test\n' > "$TEMP_DIR/install/auths/account.json"
printf 'log-test\n' > "$TEMP_DIR/install/logs/app.log"
printf 'services: {}\n' > "$TEMP_DIR/install/docker-compose.yml"

container_exists() {
  case "$1" in
    cli-proxy-api|cpa-manager-plus) return 0 ;;
    *) return 1 ;;
  esac
}

active_cpam_container() {
  printf 'cpa-manager-plus\n'
}

docker() {
  case "${1:-}" in
    inspect) printf 'true\n' ;;
    stop)
      printf 'stop %s\n' "$2" >> "$TRACE_FILE"
      ;;
    start)
      printf 'start %s\n' "$2" >> "$TRACE_FILE"
      ;;
    *) return 1 ;;
  esac
}

BACKUP_FILE="$TEMP_DIR/backup.tar.gz"
create_consistent_snapshot_archive \
  "$TEMP_DIR/install" \
  "$BACKUP_FILE" \
  all \
  docker-compose.yml auths logs cpa-manager-data

verify_snapshot_archive "$BACKUP_FILE"

EXPECTED_TRACE=$'stop cpa-manager-plus\nstop cli-proxy-api\nstart cli-proxy-api\nstart cpa-manager-plus'
ACTUAL_TRACE="$(cat "$TRACE_FILE")"
if [ "$ACTUAL_TRACE" != "$EXPECTED_TRACE" ]; then
  printf '容器停止或恢复顺序不正确。\n期望：\n%s\n实际：\n%s\n' "$EXPECTED_TRACE" "$ACTUAL_TRACE" >&2
  exit 1
fi

printf '一致性快照模拟检查通过。\n'

# 验证不停机备份会生成可读的 SQLite 在线快照和备份清单。
if [ -n "$PYTHON_BIN" ]; then
  rm -f "$TEMP_DIR/install/cpa-manager-data/usage.sqlite"
  "$PYTHON_BIN" - "$TEMP_DIR/install/cpa-manager-data/usage.sqlite" <<'PY'
import sqlite3
import sys

db = sqlite3.connect(sys.argv[1])
db.execute("create table if not exists usage_events (id integer primary key, value text)")
db.execute("insert into usage_events(value) values ('online-backup-test')")
db.commit()
db.close()
PY
  printf 'data-key-test\n' > "$TEMP_DIR/install/cpa-manager-data/data.key"
  printf 'remote-management:\n  secret-key: "test"\n' > "$TEMP_DIR/install/config.yaml"
  printf 'MGT_KEY=test\n' > "$TEMP_DIR/install/.secrets.txt"

  ONLINE_BACKUP_FILE="$TEMP_DIR/online-backup.tar.gz"
  create_online_snapshot_archive "$TEMP_DIR/install" "$ONLINE_BACKUP_FILE"
  verify_snapshot_archive "$ONLINE_BACKUP_FILE"
  tar -tzf "$ONLINE_BACKUP_FILE" | grep -Fq './SNAPSHOT-MANIFEST.txt'
  tar -tzf "$ONLINE_BACKUP_FILE" | grep -Fq './cpa-manager-data/usage.sqlite'
  tar -xOf "$ONLINE_BACKUP_FILE" ./SNAPSHOT-MANIFEST.txt | grep -Fq '快速不停机快照'

  create_snapshot_record "$TEMP_DIR/install" manual manual "自动测试备注" online
  [ -f "$CREATED_SNAPSHOT_DIR/snapshot.tar.gz" ]
  [ -f "$CREATED_SNAPSHOT_DIR/metadata.env" ]
  [ "$(snapshot_metadata_value "$CREATED_SNAPSHOT_DIR/metadata.env" format_version)" = "3" ]
  [ "$(snapshot_metadata_value "$CREATED_SNAPSHOT_DIR/metadata.env" snapshot_type)" = "manual" ]
  [ "$(snapshot_metadata_value "$CREATED_SNAPSHOT_DIR/metadata.env" protection_point)" = "false" ]
  [ "$(snapshot_metadata_value "$CREATED_SNAPSHOT_DIR/metadata.env" primary_archive)" = "snapshot.tar.gz" ]
  validate_snapshot_metadata "$CREATED_SNAPSHOT_DIR/metadata.env"
  [ "$(snapshot_metadata_value "$CREATED_SNAPSHOT_DIR/metadata.env" script_version)" = "$SCRIPT_VERSION" ]
  [ "$(snapshot_metadata_value "$CREATED_SNAPSHOT_DIR/metadata.env" restore_scope)" = "managed-deployment" ]
  [ "$(snapshot_metadata_value "$CREATED_SNAPSHOT_DIR/metadata.env" remark)" = "自动测试备注" ]
  snapshot_can_be_deleted manual manual-2026-07-12-000000
  snapshot_can_be_deleted system scheduled-2026-07-12-030000
  if snapshot_can_be_deleted system pre-upgrade-2026-07-12-000000; then
    printf '升级前系统保护点不应允许通过普通入口删除。\n' >&2
    exit 1
  fi
  create_snapshot_record "$TEMP_DIR/install" system scheduled "系统保护点测试" online
  [ "$(snapshot_metadata_value "$CREATED_SNAPSHOT_DIR/metadata.env" snapshot_type)" = "system" ]
  [ "$(snapshot_metadata_value "$CREATED_SNAPSHOT_DIR/metadata.env" protection_point)" = "true" ]
  validate_snapshot_metadata "$CREATED_SNAPSHOT_DIR/metadata.env"
  SNAPSHOT_CHECKSUM="$(snapshot_metadata_value "$CREATED_SNAPSHOT_DIR/metadata.env" checksum_sha256)"
  verify_restorable_snapshot "$CREATED_SNAPSHOT_DIR/snapshot.tar.gz" "$SNAPSHOT_CHECKSUM"
  cp "$CREATED_SNAPSHOT_DIR/snapshot.tar.gz" "$TEMP_DIR/corrupted-snapshot.tar.gz"
  printf 'corrupted' >> "$TEMP_DIR/corrupted-snapshot.tar.gz"
  if verify_restorable_snapshot "$TEMP_DIR/corrupted-snapshot.tar.gz" "$SNAPSHOT_CHECKSUM"; then
    printf '被修改的快照不应通过 SHA-256 校验。\n' >&2
    exit 1
  fi
  collect_and_print_snapshots "$TEMP_DIR/install" >/dev/null
  [ "${#SNAPSHOT_DIRS[@]}" -eq 2 ]

  mkdir -p "$TEMP_DIR/install/snapshots/system"
  cp -a "$CREATED_SNAPSHOT_DIR" "$TEMP_DIR/install/snapshots/system/scheduled-2026-07-10-030000"
  cp -a "$CREATED_SNAPSHOT_DIR" "$TEMP_DIR/install/snapshots/system/scheduled-2026-07-11-030000"
  touch -t 202607100300 "$TEMP_DIR/install/snapshots/system/scheduled-2026-07-10-030000/metadata.env"
  touch -t 202607110300 "$TEMP_DIR/install/snapshots/system/scheduled-2026-07-11-030000/metadata.env"
  prune_scheduled_snapshots "$TEMP_DIR/install" 1
  [ ! -d "$TEMP_DIR/install/snapshots/system/scheduled-2026-07-10-030000" ]
  [ -d "$TEMP_DIR/install/snapshots/system/scheduled-2026-07-11-030000" ]
  printf '不停机快照与目录元数据模拟检查通过。\n'
else
  printf '本机没有可用 Python，跳过不停机 SQLite 快照模拟。\n'
fi

# 模拟归档失败，确认两个容器仍按正确顺序恢复。
: > "$TRACE_FILE"
create_snapshot_archive() {
  return 1
}

if create_consistent_snapshot_archive \
  "$TEMP_DIR/install" \
  "$TEMP_DIR/failed-backup.tar.gz" \
  all \
  docker-compose.yml auths logs cpa-manager-data; then
  printf '归档失败时一致性快照应返回失败。\n' >&2
  exit 1
fi

ACTUAL_TRACE="$(cat "$TRACE_FILE")"
if [ "$ACTUAL_TRACE" != "$EXPECTED_TRACE" ]; then
  printf '归档失败后的容器恢复顺序不正确。\n期望：\n%s\n实际：\n%s\n' "$EXPECTED_TRACE" "$ACTUAL_TRACE" >&2
  exit 1
fi

printf '一致性快照失败恢复检查通过。\n'

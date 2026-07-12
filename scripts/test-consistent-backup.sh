#!/usr/bin/env bash
set -Eeuo pipefail

export PATH="/usr/bin:/bin:/mingw64/bin:/cmd:${PATH:-}"

# 模拟运行中的 CPA 与 Manager，验证一致性备份的停机和恢复顺序。
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
create_consistent_backup_archive \
  "$TEMP_DIR/install" \
  "$BACKUP_FILE" \
  all \
  docker-compose.yml auths logs cpa-manager-data

verify_backup_archive "$BACKUP_FILE"

EXPECTED_TRACE=$'stop cpa-manager-plus\nstop cli-proxy-api\nstart cli-proxy-api\nstart cpa-manager-plus'
ACTUAL_TRACE="$(cat "$TRACE_FILE")"
if [ "$ACTUAL_TRACE" != "$EXPECTED_TRACE" ]; then
  printf '容器停止或恢复顺序不正确。\n期望：\n%s\n实际：\n%s\n' "$EXPECTED_TRACE" "$ACTUAL_TRACE" >&2
  exit 1
fi

printf '一致性备份模拟检查通过。\n'

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
  create_online_backup_archive "$TEMP_DIR/install" "$ONLINE_BACKUP_FILE"
  verify_backup_archive "$ONLINE_BACKUP_FILE"
  tar -tzf "$ONLINE_BACKUP_FILE" | grep -Fq './BACKUP-MANIFEST.txt'
  tar -tzf "$ONLINE_BACKUP_FILE" | grep -Fq './cpa-manager-data/usage.sqlite'
  tar -xOf "$ONLINE_BACKUP_FILE" ./BACKUP-MANIFEST.txt | grep -Fq '快速不停机备份'
  printf '不停机备份模拟检查通过。\n'
else
  printf '本机没有可用 Python，跳过不停机 SQLite 备份模拟；CI 会执行。\n'
fi

# 模拟归档失败，确认两个容器仍按正确顺序恢复。
: > "$TRACE_FILE"
create_backup_archive() {
  return 1
}

if create_consistent_backup_archive \
  "$TEMP_DIR/install" \
  "$TEMP_DIR/failed-backup.tar.gz" \
  all \
  docker-compose.yml auths logs cpa-manager-data; then
  printf '归档失败时一致性备份应返回失败。\n' >&2
  exit 1
fi

ACTUAL_TRACE="$(cat "$TRACE_FILE")"
if [ "$ACTUAL_TRACE" != "$EXPECTED_TRACE" ]; then
  printf '归档失败后的容器恢复顺序不正确。\n期望：\n%s\n实际：\n%s\n' "$EXPECTED_TRACE" "$ACTUAL_TRACE" >&2
  exit 1
fi

printf '一致性备份失败恢复检查通过。\n'

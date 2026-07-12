#!/usr/bin/env bash
set -Eeuo pipefail

export PATH="/usr/bin:/bin:/mingw64/bin:/cmd:${PATH:-}"

# 使用隔离目录验证配置体检的通过与阻断结果，不修改真实部署。
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
  printf '本机没有可用 Python，跳过配置体检 SQLite 模拟。\n'
  exit 0
fi
export PYTHON_BIN

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
INSTALL_ROOT="$TEMP_DIR/install"
mkdir -p "$INSTALL_ROOT/auths" "$INSTALL_ROOT/cpa-manager-data" "$INSTALL_ROOT/snapshots"
chmod 700 "$INSTALL_ROOT/snapshots"
cat > "$INSTALL_ROOT/docker-compose.yml" <<'EOF'
services:
  cli-proxy-api:
    image: example/cpa:latest
EOF
cat > "$INSTALL_ROOT/config.yaml" <<'EOF'
usage-statistics-enabled: true
remote-management:
  allow-remote: true
  secret-key: "test"
EOF
printf 'API_KEY=test\n' > "$INSTALL_ROOT/.secrets.txt"
printf 'data-key\n' > "$INSTALL_ROOT/cpa-manager-data/data.key"
chmod 600 "$INSTALL_ROOT/.secrets.txt" "$INSTALL_ROOT/cpa-manager-data/data.key"
"$PYTHON_BIN" - "$INSTALL_ROOT/cpa-manager-data/usage.sqlite" <<'PY'
import sqlite3
import sys

db = sqlite3.connect(sys.argv[1])
db.execute("create table if not exists usage_events (id integer primary key)")
db.commit()
db.close()
PY

collect_runtime_status() {
  RUNTIME_INSTALL_DIR="$INSTALL_ROOT"
  RUNTIME_INSTALL_TYPE="plus"
  RUNTIME_PLUS_EXISTS="false"
  RUNTIME_LEGACY_EXISTS="false"
}
compose_in_dir() {
  return 0
}
detect_cpa_port() {
  printf '8317\n'
}
detect_cpam_port() {
  printf '18317\n'
}
df() {
  printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
  printf 'mock 10485760 1024 8388608 1%% /\n'
}

DOCTOR_OUTPUT="$(configuration_doctor)"
grep -Fq '配置体检通过' <<<"$DOCTOR_OUTPUT"
grep -Fq 'Manager SQLite quick_check 通过' <<<"$DOCTOR_OUTPUT"

rm -f "$INSTALL_ROOT/cpa-manager-data/data.key"
if configuration_doctor >/dev/null 2>&1; then
  printf '缺少 data.key 时配置体检应返回失败。\n' >&2
  exit 1
fi

printf '配置体检模拟检查通过。\n'

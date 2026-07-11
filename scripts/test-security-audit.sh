#!/usr/bin/env bash
set -Eeuo pipefail

export PATH="/usr/bin:/bin:/mingw64/bin:/cmd:${PATH:-}"

# 验证访问来源提取会统计公开地址，并排除内网、回环和保留地址。
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=cpa-cpam-manager.sh
NO_COLOR=1 source "$ROOT_DIR/cpa-cpam-manager.sh"

if [ -n "${PYTHON_BIN:-}" ] && "$PYTHON_BIN" -c 'import ipaddress' >/dev/null 2>&1; then
  :
elif python3 -c 'import ipaddress' >/dev/null 2>&1; then
  PYTHON_BIN=python3
elif python -c 'import ipaddress' >/dev/null 2>&1; then
  PYTHON_BIN=python
else
  printf '本机没有可用 Python，跳过安全巡检 IP 提取模拟；CI 会执行。\n'
  exit 0
fi
export PYTHON_BIN

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
mkdir -p "$TEMP_DIR/install/logs"
cat > "$TEMP_DIR/install/logs/access.log" <<'EOF'
request from 8.8.8.8 status=200
request from 8.8.8.8 status=200
request from 1.1.1.1 status=401
request from 10.0.0.8 status=403
request from 127.0.0.1 status=200
request from 192.168.1.20 status=200
request from 2606:4700:4700:0000:0000:0000:0000:1111 status=200
EOF

container_exists() {
  return 1
}

REPORT="$(collect_recent_access_ips "$TEMP_DIR/install" "$TEMP_DIR/sample.log")"
grep -Fq $'2\t8.8.8.8' <<<"$REPORT"
grep -Fq $'1\t1.1.1.1' <<<"$REPORT"
grep -Fq $'1\t2606:4700:4700::1111' <<<"$REPORT"
if grep -Eq '10\.0\.0\.8|127\.0\.0\.1|192\.168\.1\.20' <<<"$REPORT"; then
  printf '安全巡检不应包含内网或回环地址。\n' >&2
  exit 1
fi

printf '安全巡检 IP 提取模拟检查通过。\n'

#!/usr/bin/env bash
set -Eeuo pipefail

export PATH="/usr/bin:/bin:/mingw64/bin:/cmd:${PATH:-}"

# 验证访问来源会按成功/失败分类，且公网、内网和回环地址均进入本地统计。
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
request from 9.9.9.9 status=500
request from 208.67.222.222 forbidden
request from 4.2.2.2 status=302
request from 4.2.2.1
request from 10.0.0.8 status=403
request from 127.0.0.1 status=200
request from 192.168.1.20 status=200
request from 2606:4700:4700:0000:0000:0000:0000:1111 status=200
EOF

container_exists() {
  return 1
}

REPORT="$(collect_recent_access_ips "$TEMP_DIR/install" "$TEMP_DIR/sample.log")"
grep -Fq $'success\t2\t8.8.8.8\tpublic' <<<"$REPORT"
grep -Fq $'success\t1\t2606:4700:4700::1111\tpublic' <<<"$REPORT"
grep -Fq $'failure\t1\t1.1.1.1\tpublic' <<<"$REPORT"
grep -Fq $'failure\t1\t9.9.9.9\tpublic' <<<"$REPORT"
grep -Fq $'failure\t1\t208.67.222.222\tpublic' <<<"$REPORT"
grep -Fq $'failure\t1\t10.0.0.8\tinternal' <<<"$REPORT"
grep -Fq $'success\t1\t127.0.0.1\tinternal' <<<"$REPORT"
grep -Fq $'success\t1\t192.168.1.20\tinternal' <<<"$REPORT"
if grep -Eq '4\.2\.2\.[12]' <<<"$REPORT"; then
  printf '没有明确成功或失败结果的请求不应进入排名。\n' >&2
  exit 1
fi

# 模拟 IP-API Batch，验证只有公网 IP 被发送，归属结果可回填到榜单。
cat > "$TEMP_DIR/success.tsv" <<'EOF'
2	8.8.8.8	public
1	192.168.1.20	internal
EOF
cat > "$TEMP_DIR/failure.tsv" <<'EOF'
1	1.1.1.1	public
1	10.0.0.8	internal
EOF

ask_yes_no() {
  return 0
}

curl() {
  printf '%s' '[{"status":"success","country":"美国","regionName":"Virginia","city":"Ashburn","isp":"Google LLC","as":"AS15169 Google LLC","proxy":false,"hosting":true,"query":"8.8.8.8"},{"status":"success","country":"澳大利亚","regionName":"Queensland","city":"South Brisbane","isp":"Cloudflare","as":"AS13335 Cloudflare, Inc.","proxy":false,"hosting":true,"query":"1.1.1.1"}]'
}

query_ranked_ip_geolocation \
  "$TEMP_DIR/success.tsv" \
  "$TEMP_DIR/failure.tsv" \
  "$TEMP_DIR/geo.tsv" \
  "$TEMP_DIR"
grep -Fq '8.8.8.8' "$TEMP_DIR/ip-api-request.json"
grep -Fq '1.1.1.1' "$TEMP_DIR/ip-api-request.json"
if grep -Eq '192\.168\.1\.20|10\.0\.0\.8' "$TEMP_DIR/ip-api-request.json"; then
  printf '内网地址不应发送给 IP-API Batch。\n' >&2
  exit 1
fi
grep -Fq $'8.8.8.8\t美国 / Virginia / Ashburn | AS15169 Google LLC | Google LLC | 机房' "$TEMP_DIR/geo.tsv"

RANKING="$(print_access_ip_ranking '测试排名' "$TEMP_DIR/success.tsv" '无结果' "$TEMP_DIR/geo.tsv")"
grep -Fq '美国 / Virginia / Ashburn' <<<"$RANKING"
grep -Fq '内网/本地地址' <<<"$RANKING"

printf '安全巡检 IP 提取模拟检查通过。\n'

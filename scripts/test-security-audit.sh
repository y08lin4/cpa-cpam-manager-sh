#!/usr/bin/env bash
set -Eeuo pipefail

export PATH="/usr/bin:/bin:/mingw64/bin:/cmd:${PATH:-}"

# 验证消费行为与管理行为严格分离，并分别保留成功、失败、内网和公网统计。
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
  printf '本机没有可用 Python，跳过安全巡检 IP 提取模拟。\n'
  exit 0
fi
export PYTHON_BIN

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
mkdir -p "$TEMP_DIR/install/logs"
cat > "$TEMP_DIR/install/logs/access.log" <<'EOF'
[2026-07-12 08:00:00] [abcd1234] [info ] [gin_logger.go:97] 200 |         120ms |         8.8.8.8 | POST    "/v1/chat/completions"
[2026-07-12 08:00:00] [abcd1234] [info ] [gin_logger.go:97] 200 |         120ms |         8.8.8.8 | POST    "/v1/chat/completions"
[2026-07-12 08:01:00] [efgh5678] [warn ] [gin_logger.go:99] 401 |           2ms |         1.1.1.1 | POST    "/v1/responses"
[2026-07-12 08:02:00] [ijkl9012] [info ] [gin_logger.go:97] 200 |           3ms |         9.9.9.9 | GET     "/v0/management/config"
[2026-07-12 08:03:00] [mnop3456] [warn ] [gin_logger.go:99] 403 |           4ms |        10.0.0.8 | PATCH   "/v0/management/auth-files/status"
[2026-07-12 08:04:00] [qrst7890] [info ] [gin_logger.go:97] 200 |           1ms |       127.0.0.1 | GET     "/healthz"
[2026-07-12 08:05:00] [uvwx1234] [info ] [gin_logger.go:97] 200 |           1ms |    192.168.1.20 | GET     "/v1/models"
[2026-07-12 08:06:00] [yzab5678] [info ] [gin_logger.go:97] 200 |           5ms |         4.2.2.2 | GET     "/unknown-path"
[2026-07-12 08:07:00] [cdef9012] [info ] [gin_logger.go:97] 302 |           1ms |         4.2.2.1 | POST    "/v1/chat/completions"
[2026-07-12 08:08:00] [ghij3456] [info ] [gin_logger.go:97] 200 |          30ms | 2606:4700:4700::1111 | POST    "/v1beta/models/gemini:generateContent"
2026/07/12 08:09:00 http PUT /usage-service/config status=200 duration=2ms remote=172.18.0.1:45678
2026/07/12 08:10:00 http GET /health status=200 duration=1ms remote=[::1]:45679
request from 208.67.222.222 status=500
EOF

container_exists() {
  return 1
}

REPORT="$(collect_recent_access_ips "$TEMP_DIR/install" "$TEMP_DIR/sample.log")"
grep -Fq $'ip\tconsumption\tsuccess\t1\t8.8.8.8\tpublic' <<<"$REPORT"
grep -Fq $'ip\tconsumption\tsuccess\t1\t2606:4700:4700::1111\tpublic' <<<"$REPORT"
grep -Fq $'ip\tconsumption\tfailure\t1\t1.1.1.1\tpublic' <<<"$REPORT"
grep -Fq $'auth\tconsumption\t1\t1.1.1.1\tpublic' <<<"$REPORT"
grep -Fq $'ip\tmanagement\tsuccess\t1\t9.9.9.9\tpublic' <<<"$REPORT"
grep -Fq $'ip\tmanagement\tsuccess\t1\t172.18.0.1\tinternal' <<<"$REPORT"
grep -Fq $'ip\tmanagement\tfailure\t1\t10.0.0.8\tinternal' <<<"$REPORT"
grep -Fq $'auth\tmanagement\t1\t10.0.0.8\tinternal' <<<"$REPORT"
grep -Fq $'event\tsuccess\t1\tGET\t/v0/management/config' <<<"$REPORT"
grep -Fq $'event\tsuccess\t1\tPUT\t/usage-service/config' <<<"$REPORT"
grep -Fq $'diagnostic\tfiltered\t3' <<<"$REPORT"
grep -Fq $'diagnostic\tunclassified\t1' <<<"$REPORT"
grep -Fq $'diagnostic\tno_result\t1' <<<"$REPORT"
if grep -Eq '208\.67\.222\.222|127\.0\.0\.1|192\.168\.1\.20' <<<"$REPORT"; then
  printf '无路径日志、健康检查和模型列表不应进入任何行为榜单。\n' >&2
  exit 1
fi

# 直接检查两个审计页面，防止消费与管理结果再次混在一起。
detect_install_dir() {
  printf '%s/install\n' "$TEMP_DIR"
}
ask_yes_no() {
  return 1
}
CONSUMPTION_OUTPUT="$(behavior_audit consumption)"
grep -Fq '消费成功 IP 排名' <<<"$CONSUMPTION_OUTPUT"
grep -Fq '消费失败 IP 排名' <<<"$CONSUMPTION_OUTPUT"
grep -Fq '8.8.8.8' <<<"$CONSUMPTION_OUTPUT"
if grep -Eq '9\.9\.9\.9|/v0/management/config' <<<"$CONSUMPTION_OUTPUT"; then
  printf '消费行为审计混入了管理行为。\n' >&2
  exit 1
fi

MANAGEMENT_OUTPUT="$(behavior_audit management)"
grep -Fq '管理操作成功 IP 排名' <<<"$MANAGEMENT_OUTPUT"
grep -Fq '管理操作失败 IP 排名' <<<"$MANAGEMENT_OUTPUT"
grep -Fq '/v0/management/config' <<<"$MANAGEMENT_OUTPUT"
if grep -Eq '8\.8\.8\.8|/v1/chat/completions' <<<"$MANAGEMENT_OUTPUT"; then
  printf '管理行为审计混入了消费行为。\n' >&2
  exit 1
fi

# 模拟 IP-API Batch，验证只有公网 IP 被发送，归属结果可回填到榜单。
if command -v jq >/dev/null 2>&1; then
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
else
  printf '本机没有 jq，跳过 IP-API Batch 模拟。\n'
fi

printf '消费行为与管理行为审计分离模拟检查通过。\n'

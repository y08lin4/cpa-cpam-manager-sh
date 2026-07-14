#!/usr/bin/env bash
set -Eeuo pipefail

# 兼容由 Windows 外部程序直接启动、未加载 profile 的 Git Bash。
export PATH="/usr/bin:/bin:/mingw64/bin:/cmd:${PATH:-}"

# 使用模拟 Docker 输出检查终端状态卡，不需要本机运行 Docker daemon。
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=cpa-cpam-manager.sh
NO_COLOR=1 source "$ROOT_DIR/cpa-cpam-manager.sh"

container_exists() {
  case "$1" in
    cli-proxy-api|cpa-manager) return 0 ;;
    *) return 1 ;;
  esac
}

docker() {
  case "${1:-} ${2:-}" in
    "info ") return 0 ;;
    "inspect -f")
      case "${4:-}" in
        cli-proxy-api)
          if [[ "$3" == *State.Status* ]]; then printf 'running\n'; else printf 'eceasy/cli-proxy-api:latest\n'; fi
          ;;
        cpa-manager)
          if [[ "$3" == *State.Status* ]]; then printf 'exited\n'; else printf 'seakee/cpa-manager:latest\n'; fi
          ;;
      esac
      ;;
    "port cli-proxy-api") printf '0.0.0.0:8317\n[::]:8317\n' ;;
    "port cpa-manager") printf '0.0.0.0:18317\n[::]:18317\n' ;;
    *) return 1 ;;
  esac
}

OUTPUT="$(show_menu_status)"
printf '%s\n' "$OUTPUT"

grep -Fq '✓  CLIProxyAPI' <<<"$OUTPUT"
grep -Fq '状态：运行中' <<<"$OUTPUT"
grep -Fq '端口：8317 -> 8317/tcp' <<<"$OUTPUT"
grep -Fq '✗  旧 CPA-Manager' <<<"$OUTPUT"
grep -Fq '状态：已停止' <<<"$OUTPUT"
grep -Fq '端口：18317 -> 18317/tcp' <<<"$OUTPUT"
if grep -Fq '1455' <<<"$OUTPUT"; then
  printf '状态卡不应显示非主端口。\n' >&2
  exit 1
fi
collect_runtime_status "$DEFAULT_INSTALL_DIR"
[ "$RUNTIME_INSTALL_TYPE" = "legacy" ]
[ "$RUNTIME_MANAGER_CONTAINER" = "$LEGACY_CPAM_CONTAINER" ]
[ "$RUNTIME_CPA_STATE" = "running" ]
[ "$RUNTIME_LEGACY_STATE" = "exited" ]
[ "$RUNTIME_CPA_HOST_PORT" = "8317" ]
[ "$RUNTIME_MANAGER_HOST_PORT" = "18317" ]

# 已完成采集后，兼容端口函数只读取统一结果，不再次访问 Docker。
docker() {
  return 1
}
RUNTIME_INSTALL_DIR="$DEFAULT_INSTALL_DIR"
RUNTIME_CPA_HOST_PORT="98317"
RUNTIME_MANAGER_HOST_PORT="28317"
[ "$(detect_cpa_port "$DEFAULT_INSTALL_DIR")" = "98317" ]
[ "$(detect_cpam_port "$DEFAULT_INSTALL_DIR")" = "28317" ]

MENU_OUTPUT="$(print_main_menu)"
grep -Fq '7) 配置体检（只读）' <<<"$MENU_OUTPUT"
grep -Fq '15) 删除指定快照' <<<"$MENU_OUTPUT"
grep -Fq '16) 定时快照设置' <<<"$MENU_OUTPUT"
grep -Fq '17) 迁移评估（只读）' <<<"$MENU_OUTPUT"
grep -Fq '20) 消费行为审计' <<<"$MENU_OUTPUT"
grep -Fq '21) 管理行为审计' <<<"$MENU_OUTPUT"
if grep -Fq '查看迁移计划' <<<"$MENU_OUTPUT"; then
  printf '迁移计划已合并进迁移评估，不应保留独立入口。\n' >&2
  exit 1
fi
if grep -Fq '安全巡检 / 24h IP' <<<"$MENU_OUTPUT"; then
  printf '主菜单不应继续显示混合行为的旧安全巡检入口。\n' >&2
  exit 1
fi
HELP_OUTPUT="$(print_help)"
if grep -Eq '(^|[[:space:]])security([[:space:]]|$)|安全巡检|24h IP' <<<"$HELP_OUTPUT"; then
  printf '帮助文本不应继续暴露旧混合行为入口。\n' >&2
  exit 1
fi
if grep -Eq '(^|[[:space:]])backup([[:space:]]|$)|backups/' <<<"$HELP_OUTPUT"; then
  printf '帮助文本不应继续暴露旧备份命令或目录叫法。\n' >&2
  exit 1
fi
[ ! -e "$ROOT_DIR/backups" ]
[ "$(grep -c '^backups/$' "$ROOT_DIR/.gitignore" || true)" -eq 0 ]

# 验证全局确认默认值生效，且非交互环境不会因为默认 Y 自动执行。
if [ "$CONFIRM_DEFAULT" != "Y" ]; then
  printf '全局确认默认值应为 Y。\n' >&2
  exit 1
fi
if ask_yes_no "非交互确认测试" "Y"; then
  printf '非交互环境不应自动确认。\n' >&2
  exit 1
fi

# 验证两类管理密钥能够安全替换到配置文件。
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
cat > "$TEMP_DIR/config.yaml" <<'EOF'
remote-management:
  allow-remote: true
  secret-key: "old-management-key"
debug: false
EOF
cat > "$TEMP_DIR/docker-compose.yml" <<'EOF'
services:
  cpa-manager-plus:
    environment:
      CPA_MANAGER_ADMIN_KEY: "old-admin-key"
EOF
replace_cpa_management_key "$TEMP_DIR/config.yaml" "mgt-cpa-new-key"
replace_compose_admin_key "$TEMP_DIR/docker-compose.yml" "cpamp_new-key"
grep -Fq 'secret-key: "mgt-cpa-new-key"' "$TEMP_DIR/config.yaml"
grep -Fq 'CPA_MANAGER_ADMIN_KEY: "cpamp_new-key"' "$TEMP_DIR/docker-compose.yml"

# 验证统一迁移评估会在一次只读执行中同时输出条件检查和迁移计划。
preflight_cpa_cpam() {
  RUNTIME_INSTALL_TYPE="legacy"
  printf '迁移条件检查完成\n'
}
MIGRATION_ASSESS_OUTPUT="$(migration_assess)"
grep -Fq '迁移条件检查完成' <<<"$MIGRATION_ASSESS_OUTPUT"
grep -Fq '迁移计划（未执行任何写操作）' <<<"$MIGRATION_ASSESS_OUTPUT"

printf '终端界面模拟检查通过。\n'

#!/usr/bin/env bash
set -Eeuo pipefail

# 验证计划任务中心的版本检查只读边界，不需要 Docker 或 systemd。
export PATH="/usr/bin:/bin:/mingw64/bin:/cmd:${PATH:-}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=cpa-cpam-manager.sh
NO_COLOR=1 source "$ROOT_DIR/cpa-cpam-manager.sh"

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
INSTALL_DIR="$TEMP_DIR/install"
mkdir -p "$INSTALL_DIR"

collect_runtime_status() {
  RUNTIME_INSTALL_DIR="$INSTALL_DIR"
  RUNTIME_INSTALL_TYPE="plus"
  RUNTIME_CPA_EXISTS="true"
  RUNTIME_PLUS_EXISTS="true"
  RUNTIME_CPA_IMAGE="example/cpa:latest"
  RUNTIME_PLUS_IMAGE="example/plus:latest"
  RUNTIME_CPA_IMAGE_ID="sha256:current-cpa"
  RUNTIME_PLUS_IMAGE_ID="sha256:current-plus"
}

pull_image_quietly() {
  return 0
}

image_ref_id() {
  case "$1" in
    example/cpa:latest) printf 'sha256:target-cpa\n' ;;
    example/plus:latest) printf 'sha256:current-plus\n' ;;
    *) return 1 ;;
  esac
}

image_display_version() {
  printf '%s\n' "$1"
}

if check_available_versions >"$TEMP_DIR/report.txt"; then
  printf '发现更新时版本检查不应返回成功状态。\n' >&2
  exit 1
else
  [ "$?" -eq 10 ] || {
    printf '发现更新时应返回状态码 10。\n' >&2
    exit 1
  }
fi
grep -Fq '发现新镜像，可升级' "$TEMP_DIR/report.txt"

run_scheduled_version_check >/dev/null
grep -Fq '发现新镜像，可升级' "$INSTALL_DIR/state/version-check.latest.txt"
[ ! -e "$INSTALL_DIR/docker-compose.yml" ]

MENU_OUTPUT="$(print_main_menu)"
grep -Fq '16) 计划任务中心（版本检查 / 自动快照）' <<<"$MENU_OUTPUT"
HELP_OUTPUT="$(print_help)"
grep -Fq 'task-center' <<<"$HELP_OUTPUT"
grep -Fq 'scheduled-version-check' <<<"$HELP_OUTPUT" || {
  printf '帮助文本应列出受管的定时版本检查命令。\n' >&2
  exit 1
}

printf '计划任务中心版本检查模拟检查通过。\n'

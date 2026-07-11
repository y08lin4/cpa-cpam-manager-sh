#!/usr/bin/env bash
set -Eeuo pipefail

# 兼容由 Windows 外部程序直接启动、未加载 profile 的 Git Bash。
export PATH="/usr/bin:/bin:/mingw64/bin:/cmd:${PATH:-}"

# 使用模拟 Docker 输出检查终端状态卡，不需要本机运行 Docker daemon。
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../cpa-cpam-manager.sh
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

printf '终端界面模拟检查通过。\n'

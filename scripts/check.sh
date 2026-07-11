#!/usr/bin/env bash
set -Eeuo pipefail

# 兼容由 Windows 外部程序直接启动、未加载 profile 的 Git Bash。
export PATH="/usr/bin:/bin:/mingw64/bin:/cmd:${PATH:-}"

# 项目统一静态检查入口：本地和 CI 使用相同的基础检查命令。
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_FILE="$ROOT_DIR/cpa-cpam-manager.sh"

# Git Bash 由外部程序直接启动时，PATH 可能不包含 Git 的 cmd 目录。
if command -v git >/dev/null 2>&1; then
  GIT_BIN="$(command -v git)"
elif [ -x /cmd/git.exe ]; then
  GIT_BIN=/cmd/git.exe
elif [ -x /mingw64/bin/git.exe ]; then
  GIT_BIN=/mingw64/bin/git.exe
else
  printf '未找到 git，无法执行仓库检查。\n' >&2
  exit 1
fi

printf '[1/3] Bash 语法检查\n'
bash -n "$SCRIPT_FILE"

printf '[2/3] Git 空白错误检查\n'
"$GIT_BIN" -C "$ROOT_DIR" diff --check

printf '[3/3] ShellCheck\n'
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$SCRIPT_FILE" "$ROOT_DIR/scripts/check.sh"
else
  printf '未安装 shellcheck，已跳过；CI 会执行该检查。\n'
fi

printf '[附加] 终端界面模拟检查\n'
bash "$ROOT_DIR/scripts/test-terminal-ui.sh" >/dev/null
printf '终端界面模拟检查通过。\n'

printf '静态检查完成。\n'

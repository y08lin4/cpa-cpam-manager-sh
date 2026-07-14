#!/usr/bin/env bash
set -Eeuo pipefail

# 兼容由 Windows 外部程序直接启动、未加载 profile 的 Git Bash。
export PATH="/usr/bin:/bin:/mingw64/bin:/cmd:${PATH:-}"

# 项目统一静态检查入口，本地开发和服务器验收使用相同命令。
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
  shellcheck -x "$SCRIPT_FILE" "$ROOT_DIR"/scripts/*.sh
else
  printf '未安装 shellcheck，已跳过；建议安装后重新执行。\n'
fi

printf '[附加 1/5] 终端界面模拟检查\n'
bash "$ROOT_DIR/scripts/test-terminal-ui.sh" >/dev/null
printf '终端界面模拟检查通过。\n'

printf '[附加 2/5] 一致性快照模拟检查\n'
bash "$ROOT_DIR/scripts/test-consistent-backup.sh" >/dev/null
printf '一致性快照模拟检查通过。\n'

printf '[附加 3/5] 升级版本展示模拟检查\n'
bash "$ROOT_DIR/scripts/test-upgrade-version.sh" >/dev/null
printf '升级版本展示模拟检查通过。\n'

printf '[附加 4/5] 消费与管理行为审计分离模拟检查\n'
bash "$ROOT_DIR/scripts/test-security-audit.sh" >/dev/null
printf '消费与管理行为审计分离模拟检查通过。\n'

printf '[附加 5/6] 配置体检模拟检查\n'
bash "$ROOT_DIR/scripts/test-configuration-doctor.sh" >/dev/null
printf '配置体检模拟检查通过。\n'

printf '[附加 6/6] 计划任务中心模拟检查\n'
bash "$ROOT_DIR/scripts/test-task-center.sh" >/dev/null
printf '计划任务中心模拟检查通过。\n'

printf '静态检查完成。\n'

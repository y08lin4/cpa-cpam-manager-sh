#!/usr/bin/env bash
set -Eeuo pipefail

export PATH="/usr/bin:/bin:/mingw64/bin:/cmd:${PATH:-}"

# 验证升级版本展示优先使用 OCI 版本，并在缺少版本时回退到 revision/镜像 ID。
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=cpa-cpam-manager.sh
NO_COLOR=1 source "$ROOT_DIR/cpa-cpam-manager.sh"

docker() {
  if [ "${1:-}" = "image" ] && [ "${2:-}" = "inspect" ]; then
    local template="${4:-}"
    local image_id="${5:-}"
    if [[ "$template" == *org.opencontainers.image.version* ]]; then
      case "$image_id" in
        sha256:111111111111*) printf 'v1.2.3\n' ;;
        *) printf '<no value>\n' ;;
      esac
    elif [[ "$template" == *org.opencontainers.image.revision* ]]; then
      case "$image_id" in
        sha256:222222222222*) printf 'abcdef1234567890\n' ;;
        *) printf '<no value>\n' ;;
      esac
    else
      printf '%s\n' "$image_id"
    fi
    return 0
  fi
  return 1
}

VERSION_OUTPUT="$(image_display_version 'sha256:111111111111aaaaaaaa' 'example/app:latest')"
[ "$VERSION_OUTPUT" = 'v1.2.3 (111111111111)' ] || {
  printf 'OCI 版本展示不正确: %s\n' "$VERSION_OUTPUT" >&2
  exit 1
}

REVISION_OUTPUT="$(image_display_version 'sha256:222222222222bbbbbbbb' 'example/app:latest')"
[ "$REVISION_OUTPUT" = 'example/app:latest@abcdef123456 (222222222222)' ] || {
  printf 'revision 回退展示不正确: %s\n' "$REVISION_OUTPUT" >&2
  exit 1
}

ID_OUTPUT="$(image_display_version 'sha256:333333333333cccccccc' 'example/app:stable')"
[ "$ID_OUTPUT" = 'example/app:stable (333333333333)' ] || {
  printf '镜像 ID 回退展示不正确: %s\n' "$ID_OUTPUT" >&2
  exit 1
}

printf '升级版本展示模拟检查通过。\n'

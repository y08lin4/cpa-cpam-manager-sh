#!/usr/bin/env bash
set -Eeuo pipefail

DEFAULT_INSTALL_DIR="/opt/cliproxy-cpam"
DEFAULT_CPA_HOST_PORT="8317"
DEFAULT_CPAM_HOST_PORT="18317"
SCRIPT_VERSION="2026.07.12"
CPA_IMAGE="${CPA_IMAGE:-eceasy/cli-proxy-api:latest}"
CPAM_IMAGE="${CPAM_IMAGE:-seakee/cpa-manager-plus:latest}"
OLD_PANEL_CONTAINER="cpa-management-center"
CPA_CONTAINER="cli-proxy-api"
CPAM_CONTAINER="cpa-manager-plus"
LEGACY_CPAM_CONTAINER="cpa-manager"
CPA_INTERNAL_PORT="8317"
CPAM_INTERNAL_PORT="18317"
CPA_MANAGER_SETUP_UPSTREAM="http://cli-proxy-api:8317"
IP_API_BATCH_URL="${IP_API_BATCH_URL:-http://ip-api.com/batch}"
CONFIRM_DEFAULT="${CONFIRM_DEFAULT:-Y}"

# 终端配色。设置 NO_COLOR=1 时关闭颜色，兼容不支持 ANSI 的终端和日志采集场景。
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  COLOR_GREEN='\033[1;32m'
  COLOR_YELLOW='\033[1;33m'
  COLOR_RED='\033[1;31m'
  COLOR_CYAN='\033[1;36m'
  COLOR_BOLD='\033[1m'
  COLOR_RESET='\033[0m'
else
  COLOR_GREEN=''
  COLOR_YELLOW=''
  COLOR_RED=''
  COLOR_CYAN=''
  COLOR_BOLD=''
  COLOR_RESET=''
fi

ICON_OK="${COLOR_GREEN}✓${COLOR_RESET}"
ICON_WARN="${COLOR_YELLOW}!${COLOR_RESET}"
ICON_ERROR="${COLOR_RED}✗${COLOR_RESET}"

# -----------------------------------------------------------------------------
# 基础输出与交互
# -----------------------------------------------------------------------------

log() {
  printf '%b[INFO]%b %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$*"
}

warn() {
  printf '%b[WARN]%b %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$*" >&2
}

err() {
  printf '%b[ERROR]%b %s\n' "$COLOR_RED" "$COLOR_RESET" "$*" >&2
}

# 输出统一的区块标题，避免状态、预检和菜单内容挤在一起。
print_section() {
  local title="$1"
  printf '\n%b%s%b\n' "$COLOR_BOLD$COLOR_CYAN" "$title" "$COLOR_RESET"
  printf '%s\n' '────────────────────────────────────────────────────────'
}

clear_screen() {
  if [ -t 1 ]; then
    printf '\033[2J\033[H'
  fi
}

pause_before_menu() {
  if [ -t 0 ]; then
    printf '\n按 Enter 返回主菜单...'
    read -r _ || true
  fi
}

# -----------------------------------------------------------------------------
# 系统依赖与 Docker 环境
# -----------------------------------------------------------------------------

die() {
  err "$*"
  exit 1
}

need_root() {
  if [ "${EUID}" -ne 0 ]; then
    echo "请用 root 运行"
    exit 1
  fi
}

timestamp() {
  date +"%Y-%m-%d-%H%M%S"
}

has_systemd() {
  command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

ask_yes_no() {
  local prompt="$1"
  local requested_default="${2:-Y}"
  local default="${CONFIRM_DEFAULT:-$requested_default}"
  local suffix
  local answer

  case "$default" in
    y|Y|yes|YES|Yes) default="Y" ;;
    n|N|no|NO|No) default="N" ;;
    *)
      warn "CONFIRM_DEFAULT 仅支持 Y 或 N，当前值 '$default' 无效，已使用 Y"
      default="Y"
      ;;
  esac

  if [ "${ASSUME_YES:-0}" = "1" ]; then
    warn "ASSUME_YES=1：自动确认操作：$prompt"
    return 0
  fi

  if [ "$default" = "Y" ]; then
    suffix="[Y/n]"
  else
    suffix="[y/N]"
  fi

  if [ -t 0 ]; then
    printf "%s %s: " "$prompt" "$suffix"
    read -r answer || answer=""
  else
    warn "非交互环境无法确认：$prompt；如需可信自动化，请显式设置 ASSUME_YES=1"
    return 1
  fi

  if [ -z "$answer" ]; then
    answer="$default"
  fi

  case "$answer" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

read_with_default() {
  local prompt="$1"
  local default="$2"
  local value

  if [ -t 0 ]; then
    printf "%s" "$prompt" >&2
    read -r value || value=""
  else
    value=""
  fi

  if [ -z "$value" ]; then
    printf '%s\n' "$default"
  else
    printf '%s\n' "$value"
  fi
}

validate_port() {
  local port="$1"
  if [[ ! "$port" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  if (( port < 1 || port > 65535 )); then
    return 1
  fi
  return 0
}

install_basic_deps() {
  local packages=(curl git ca-certificates openssl ufw jq python3)
  local missing=()
  local package

  for package in "${packages[@]}"; do
    case "$package" in
      curl|git|openssl|ufw|jq|python3)
        if ! command -v "$package" >/dev/null 2>&1; then
          missing+=("$package")
        fi
        ;;
      ca-certificates)
        if ! dpkg -s ca-certificates >/dev/null 2>&1; then
          missing+=("$package")
        fi
        ;;
    esac
  done

  if [ "${#missing[@]}" -eq 0 ]; then
    return 0
  fi

  command -v apt-get >/dev/null 2>&1 || die "当前系统缺少 apt-get，脚本仅支持 Debian/Ubuntu"
  log "安装基础依赖: ${missing[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y "${missing[@]}"
}

install_docker() {
  command -v curl >/dev/null 2>&1 || die "缺少 curl，无法安装 Docker"
  log "开始安装 Docker"
  bash <(curl -fsSL https://get.docker.com)

  if has_systemd; then
    systemctl enable --now docker || warn "systemctl 启动 Docker 失败，将尝试 service docker start"
  fi

  if ! docker info >/dev/null 2>&1; then
    service docker start || true
  fi
}

ensure_docker_interactive() {
  if command -v docker >/dev/null 2>&1; then
    docker --version >/dev/null 2>&1 || true
  else
    if ask_yes_no "未检测到 Docker，是否现在安装 Docker" "Y"; then
      install_docker
    else
      die "未安装 Docker，无法继续"
    fi
  fi

  if ! docker info >/dev/null 2>&1; then
    if has_systemd; then
      systemctl enable --now docker || true
    else
      service docker start || true
    fi
  fi

  docker info >/dev/null 2>&1 || die "Docker daemon 不正常，请检查 Docker 服务"

  if docker compose version >/dev/null 2>&1; then
    return 0
  fi

  warn "未检测到 docker compose plugin，尝试安装 docker-compose-plugin"
  command -v apt-get >/dev/null 2>&1 || die "当前系统缺少 apt-get，无法安装 docker-compose-plugin"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y docker-compose-plugin
  docker compose version >/dev/null 2>&1 || die "docker compose 不可用，请手动检查 Docker Compose 插件"
  log "Docker Compose 插件安装完成"
}

generate_hex() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  else
    od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

# -----------------------------------------------------------------------------
# 密钥、配置值与服务器信息
# -----------------------------------------------------------------------------

generate_api_key() {
  printf 'sk-cpa-%s\n' "$(generate_hex)"
}

generate_mgt_key() {
  printf 'mgt-cpa-%s\n' "$(generate_hex)"
}

generate_cpamp_admin_key() {
  printf 'cpamp_%s\n' "$(generate_hex)"
}

yaml_escape_double() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

get_server_ip() {
  local server_ip
  server_ip="$(curl -4fsS --max-time 3 https://api.ipify.org 2>/dev/null || true)"
  if [ -z "$server_ip" ]; then
    server_ip="你的服务器IP"
  fi
  printf '%s\n' "$server_ip"
}

load_secrets_value() {
  local secrets_file="$1"
  local key="$2"
  if [ ! -f "$secrets_file" ]; then
    return 0
  fi
  awk -v key="$key" 'BEGIN { FS="=" } $1 == key { sub(/^[^=]*=/, ""); print; exit }' "$secrets_file"
}

# -----------------------------------------------------------------------------
# 安装识别与终端状态展示
# -----------------------------------------------------------------------------

container_exists() {
  local name="$1"
  docker ps -a --format '{{.Names}}' | grep -Fxq "$name"
}

active_cpam_container() {
  collect_runtime_status
  printf '%s\n' "$RUNTIME_MANAGER_CONTAINER"
}

detect_install_type() {
  collect_runtime_status
  printf '%s\n' "$RUNTIME_INSTALL_TYPE"
}

container_primary_port() {
  local name="$1"
  local internal_port="$2"
  local mapping
  mapping="$(docker port "$name" "${internal_port}/tcp" 2>/dev/null | head -n 1 || true)"
  if [ -n "$mapping" ]; then
    printf '%s\n' "${mapping##*:}"
  else
    printf '%s\n' "未映射"
  fi
}

# 统一采集安装类型、容器、镜像、镜像 ID、状态和主端口，供菜单、状态、升级和迁移复用。
RUNTIME_INSTALL_DIR=""
RUNTIME_INSTALL_TYPE="not-installed"
RUNTIME_MANAGER_CONTAINER="$CPAM_CONTAINER"
RUNTIME_CPA_EXISTS="false"
RUNTIME_CPA_STATE="not-installed"
RUNTIME_CPA_IMAGE=""
RUNTIME_CPA_IMAGE_ID=""
RUNTIME_CPA_PORT="未映射"
RUNTIME_CPA_HOST_PORT="$DEFAULT_CPA_HOST_PORT"
RUNTIME_PLUS_EXISTS="false"
RUNTIME_PLUS_STATE="not-installed"
RUNTIME_PLUS_IMAGE=""
RUNTIME_PLUS_IMAGE_ID=""
RUNTIME_PLUS_PORT="未映射"
RUNTIME_LEGACY_EXISTS="false"
RUNTIME_LEGACY_STATE="not-installed"
RUNTIME_LEGACY_IMAGE=""
RUNTIME_LEGACY_IMAGE_ID=""
RUNTIME_LEGACY_PORT="未映射"
RUNTIME_MANAGER_HOST_PORT="$DEFAULT_CPAM_HOST_PORT"

collect_container_runtime() {
  local name="$1"
  local internal_port="$2"
  local prefix="$3"
  local exists="false"
  local state="not-installed"
  local image=""
  local image_id=""
  local port="未映射"

  if container_exists "$name"; then
    exists="true"
    state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || printf 'unknown')"
    image="$(docker inspect -f '{{.Config.Image}}' "$name" 2>/dev/null || true)"
    image_id="$(docker inspect -f '{{.Image}}' "$name" 2>/dev/null || true)"
    port="$(container_primary_port "$name" "$internal_port")"
  fi
  printf -v "RUNTIME_${prefix}_EXISTS" '%s' "$exists"
  printf -v "RUNTIME_${prefix}_STATE" '%s' "$state"
  printf -v "RUNTIME_${prefix}_IMAGE" '%s' "$image"
  printf -v "RUNTIME_${prefix}_IMAGE_ID" '%s' "$image_id"
  printf -v "RUNTIME_${prefix}_PORT" '%s' "$port"
}

resolve_cpa_host_port() {
  local install_dir="$1"
  local port
  local secrets_value

  if port="$(port_from_docker_mapping "$CPA_CONTAINER" "$CPA_INTERNAL_PORT")"; then
    printf '%s\n' "$port"
    return 0
  fi
  secrets_value="$(load_secrets_value "$install_dir/.secrets.txt" "CPA_API" || true)"
  if [[ "$secrets_value" =~ :([0-9]+)/v1$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  printf '%s\n' "${CPA_HOST_PORT:-$DEFAULT_CPA_HOST_PORT}"
}

resolve_manager_host_port() {
  local install_dir="$1"
  local manager_container="$2"
  local port
  local secrets_value

  if [ -n "$manager_container" ] && port="$(port_from_docker_mapping "$manager_container" "$CPAM_INTERNAL_PORT")"; then
    printf '%s\n' "$port"
    return 0
  fi
  secrets_value="$(load_secrets_value "$install_dir/.secrets.txt" "CPA_MANAGER" || true)"
  if [[ "$secrets_value" =~ :([0-9]+)/management\.html$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  printf '%s\n' "${CPAM_HOST_PORT:-$DEFAULT_CPAM_HOST_PORT}"
}

collect_runtime_status() {
  local install_dir="${1:-}"

  collect_container_runtime "$CPA_CONTAINER" "$CPA_INTERNAL_PORT" CPA
  collect_container_runtime "$CPAM_CONTAINER" "$CPAM_INTERNAL_PORT" PLUS
  collect_container_runtime "$LEGACY_CPAM_CONTAINER" "$CPAM_INTERNAL_PORT" LEGACY

  if [ "$RUNTIME_PLUS_EXISTS" = "true" ] && [ "$RUNTIME_LEGACY_EXISTS" = "true" ]; then
    RUNTIME_INSTALL_TYPE="mixed"
    RUNTIME_MANAGER_CONTAINER="$CPAM_CONTAINER"
  elif [ "$RUNTIME_PLUS_EXISTS" = "true" ]; then
    RUNTIME_INSTALL_TYPE="plus"
    RUNTIME_MANAGER_CONTAINER="$CPAM_CONTAINER"
  elif [ "$RUNTIME_LEGACY_EXISTS" = "true" ]; then
    RUNTIME_INSTALL_TYPE="legacy"
    RUNTIME_MANAGER_CONTAINER="$LEGACY_CPAM_CONTAINER"
  elif [ "$RUNTIME_CPA_EXISTS" = "true" ]; then
    RUNTIME_INSTALL_TYPE="cpa-only"
    RUNTIME_MANAGER_CONTAINER="$CPAM_CONTAINER"
  else
    RUNTIME_INSTALL_TYPE="not-installed"
    RUNTIME_MANAGER_CONTAINER="$CPAM_CONTAINER"
  fi
  if [ -n "$install_dir" ]; then
    RUNTIME_INSTALL_DIR="$install_dir"
  else
    RUNTIME_INSTALL_DIR="$(detect_install_dir)"
  fi
  RUNTIME_CPA_HOST_PORT="$(resolve_cpa_host_port "$RUNTIME_INSTALL_DIR")"
  RUNTIME_MANAGER_HOST_PORT="$(resolve_manager_host_port "$RUNTIME_INSTALL_DIR" "$RUNTIME_MANAGER_CONTAINER")"
}

render_runtime_status_card() {
  local label="$1"
  local exists="$2"
  local state="$3"
  local image="$4"
  local port="$5"
  local internal_port="$6"
  local legacy="${7:-false}"
  local icon
  local state_text

  if [ "$exists" != "true" ]; then
    printf '%b  %b%s%b\n' "$ICON_WARN" "$COLOR_YELLOW" "$label" "$COLOR_RESET"
    printf '   状态：%b未安装%b\n' "$COLOR_YELLOW" "$COLOR_RESET"
    return 0
  fi
  case "$state" in
    running) icon="$ICON_OK"; state_text="${COLOR_GREEN}运行中${COLOR_RESET}" ;;
    exited|dead) icon="$ICON_ERROR"; state_text="${COLOR_RED}已停止${COLOR_RESET}" ;;
    *) icon="$ICON_WARN"; state_text="${COLOR_YELLOW}${state}${COLOR_RESET}" ;;
  esac
  printf '%b  %b%s%b\n' "$icon" "$COLOR_BOLD" "$label" "$COLOR_RESET"
  printf '   状态：%b\n' "$state_text"
  printf '   镜像：%s\n' "${image:-未知}"
  printf '   端口：%s -> %s/tcp\n' "$port" "$internal_port"
  if [ "$legacy" = "true" ]; then
    printf '   提示：%b旧版服务，建议执行迁移评估%b\n' "$COLOR_YELLOW" "$COLOR_RESET"
  fi
}

render_collected_runtime_status() {
  render_runtime_status_card "CLIProxyAPI" "$RUNTIME_CPA_EXISTS" "$RUNTIME_CPA_STATE" "$RUNTIME_CPA_IMAGE" "$RUNTIME_CPA_PORT" "$CPA_INTERNAL_PORT"
  printf '\n'
  if [ "$RUNTIME_PLUS_EXISTS" = "true" ]; then
    render_runtime_status_card "CPA Manager Plus" "$RUNTIME_PLUS_EXISTS" "$RUNTIME_PLUS_STATE" "$RUNTIME_PLUS_IMAGE" "$RUNTIME_PLUS_PORT" "$CPAM_INTERNAL_PORT"
  elif [ "$RUNTIME_LEGACY_EXISTS" = "true" ]; then
    render_runtime_status_card "旧 CPA-Manager" "$RUNTIME_LEGACY_EXISTS" "$RUNTIME_LEGACY_STATE" "$RUNTIME_LEGACY_IMAGE" "$RUNTIME_LEGACY_PORT" "$CPAM_INTERNAL_PORT" true
  else
    render_runtime_status_card "CPA Manager Plus" false not-installed "" "未映射" "$CPAM_INTERNAL_PORT"
  fi
  if [ "$RUNTIME_PLUS_EXISTS" = "true" ] && [ "$RUNTIME_LEGACY_EXISTS" = "true" ]; then
    printf '\n'
    render_runtime_status_card "旧 CPA-Manager" "$RUNTIME_LEGACY_EXISTS" "$RUNTIME_LEGACY_STATE" "$RUNTIME_LEGACY_IMAGE" "$RUNTIME_LEGACY_PORT" "$CPAM_INTERNAL_PORT" true
    warn "同时检测到新旧 Manager，避免让两者消费同一个用量队列"
  fi
}

show_menu_status() {
  print_section "服务状态"
  if ! command -v docker >/dev/null 2>&1; then
    printf '%b  Docker 未安装\n' "$ICON_WARN"
    return 0
  fi
  if ! docker info >/dev/null 2>&1; then
    printf '%b  Docker daemon 未运行\n' "$ICON_ERROR"
    return 0
  fi

  collect_runtime_status
  render_collected_runtime_status
}

# 将镜像 ID 缩短为便于人工核对的 12 位标识。
short_image_id() {
  local image_id="$1"
  image_id="${image_id#sha256:}"
  printf '%s\n' "${image_id:0:12}"
}

container_image_id() {
  local container="$1"
  docker inspect -f '{{.Image}}' "$container" 2>/dev/null || true
}

image_ref_id() {
  local image_ref="$1"
  docker image inspect -f '{{.Id}}' "$image_ref" 2>/dev/null || true
}

# 优先显示 OCI 语义版本；上游未提供标签时使用镜像引用和短 ID。
image_display_version() {
  local image_id="$1"
  local image_ref="$2"
  local version
  local revision
  local short_id

  short_id="$(short_image_id "$image_id")"
  version="$(docker image inspect -f '{{ index .Config.Labels "org.opencontainers.image.version" }}' "$image_id" 2>/dev/null || true)"
  revision="$(docker image inspect -f '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$image_id" 2>/dev/null || true)"
  [ "$version" = "<no value>" ] && version=""
  [ "$revision" = "<no value>" ] && revision=""

  if [ -n "$version" ]; then
    printf '%s (%s)\n' "$version" "$short_id"
  elif [ -n "$revision" ]; then
    printf '%s@%.12s (%s)\n' "$image_ref" "$revision" "$short_id"
  else
    printf '%s (%s)\n' "$image_ref" "$short_id"
  fi
}

pull_image_quietly() {
  local image_ref="$1"
  if ! docker pull --quiet "$image_ref" >/dev/null; then
    err "无法检查最新镜像: $image_ref"
    return 1
  fi
}

print_upgrade_service() {
  local label="$1"
  local current_version="$2"
  local target_version="$3"
  local changed="$4"
  local icon="$ICON_OK"

  [ "$changed" = "true" ] && icon="$ICON_WARN"

  printf '%b  %b%s%b\n' "$icon" "$COLOR_BOLD" "$label" "$COLOR_RESET"
  printf '   当前：%s\n' "$current_version"
  printf '   目标：%s\n' "$target_version"
  if [ "$changed" = "true" ]; then
    printf '   结论：%b发现新镜像，可升级%b\n' "$COLOR_YELLOW" "$COLOR_RESET"
  else
    printf '   结论：%b已是最新镜像%b\n' "$COLOR_GREEN" "$COLOR_RESET"
  fi
}

# 只读检查两个服务的当前镜像与仓库镜像，不重建容器、不修改部署。
check_available_versions() {
  local install_dir
  local install_type
  local cpa_ref
  local manager_ref
  local cpa_current_id
  local manager_current_id
  local cpa_target_id
  local manager_target_id
  local cpa_changed="false"
  local manager_changed="false"

  collect_runtime_status
  install_dir="$RUNTIME_INSTALL_DIR"
  install_type="$RUNTIME_INSTALL_TYPE"
  case "$install_type" in
    legacy) warn "当前为旧 CPA-Manager，请先迁移后再检查 Plus 版本"; return 1 ;;
    mixed) warn "同时存在新旧 Manager，已跳过版本检查"; return 1 ;;
  esac
  [ "$RUNTIME_CPA_EXISTS" = "true" ] && [ "$RUNTIME_PLUS_EXISTS" = "true" ] || {
    warn "未检测到完整的 CPA + CPA Manager Plus 部署，无法检查版本"
    return 1
  }
  cpa_ref="$RUNTIME_CPA_IMAGE"
  manager_ref="$RUNTIME_PLUS_IMAGE"
  cpa_current_id="$RUNTIME_CPA_IMAGE_ID"
  manager_current_id="$RUNTIME_PLUS_IMAGE_ID"
  [ -n "$cpa_ref" ] && [ -n "$manager_ref" ] && [ -n "$cpa_current_id" ] && [ -n "$manager_current_id" ] || {
    warn "无法读取当前容器镜像信息"
    return 1
  }

  print_section "版本检查（只读）"
  printf '安装目录：%s\n' "$install_dir"
  pull_image_quietly "$cpa_ref" || return 1
  pull_image_quietly "$manager_ref" || return 1
  cpa_target_id="$(image_ref_id "$cpa_ref")"
  manager_target_id="$(image_ref_id "$manager_ref")"
  [ -n "$cpa_target_id" ] && [ -n "$manager_target_id" ] || return 1
  [ "$cpa_current_id" != "$cpa_target_id" ] && cpa_changed="true"
  [ "$manager_current_id" != "$manager_target_id" ] && manager_changed="true"
  print_upgrade_service "CLIProxyAPI" \
    "$(image_display_version "$cpa_current_id" "$cpa_ref")" \
    "$(image_display_version "$cpa_target_id" "$cpa_ref")" "$cpa_changed"
  printf '\n'
  print_upgrade_service "CPA Manager Plus" \
    "$(image_display_version "$manager_current_id" "$manager_ref")" \
    "$(image_display_version "$manager_target_id" "$manager_ref")" "$manager_changed"
  if [ "$cpa_changed" = "true" ] || [ "$manager_changed" = "true" ]; then
    return 10
  fi
  return 0
}

# -----------------------------------------------------------------------------
# 端口、Compose 与安装文件
# -----------------------------------------------------------------------------

detect_install_dir() {
  local env_install_dir="${INSTALL_DIR:-}"
  local container
  local detected

  if [ -n "$env_install_dir" ]; then
    printf '%s\n' "$env_install_dir"
    return 0
  fi

  for container in "$CPAM_CONTAINER" "$LEGACY_CPAM_CONTAINER" "$CPA_CONTAINER"; do
    if container_exists "$container"; then
      detected="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$container" 2>/dev/null || true)"
      if [ -n "$detected" ] && [ "$detected" != "<no value>" ] && [ -d "$detected" ]; then
        printf '%s\n' "$detected"
        return 0
      fi
    fi
  done

  printf '%s\n' "$DEFAULT_INSTALL_DIR"
}

port_from_docker_mapping() {
  local container="$1"
  local internal_port="$2"
  local mapping
  local port

  mapping="$(docker port "$container" "${internal_port}/tcp" 2>/dev/null | head -n 1 || true)"
  if [ -n "$mapping" ]; then
    port="${mapping##*:}"
    if validate_port "$port"; then
      printf '%s\n' "$port"
      return 0
    fi
  fi
  return 1
}

detect_cpa_port() {
  local install_dir="${1:-${RUNTIME_INSTALL_DIR:-$(detect_install_dir)}}"
  if [ "$RUNTIME_INSTALL_DIR" = "$install_dir" ] && [ -n "$RUNTIME_CPA_HOST_PORT" ]; then
    printf '%s\n' "$RUNTIME_CPA_HOST_PORT"
  else
    resolve_cpa_host_port "$install_dir"
  fi
}

detect_cpam_port() {
  local install_dir="${1:-${RUNTIME_INSTALL_DIR:-$(detect_install_dir)}}"
  if [ "$RUNTIME_INSTALL_DIR" = "$install_dir" ] && [ -n "$RUNTIME_MANAGER_HOST_PORT" ]; then
    printf '%s\n' "$RUNTIME_MANAGER_HOST_PORT"
  else
    resolve_manager_host_port "$install_dir" "$RUNTIME_MANAGER_CONTAINER"
  fi
}

ensure_compose_dir() {
  local install_dir="$1"
  [ -d "$install_dir" ] || die "安装目录不存在: $install_dir"
  [ -f "$install_dir/docker-compose.yml" ] || die "未找到 docker-compose.yml: $install_dir/docker-compose.yml"
}

compose_in_dir() {
  local install_dir="$1"
  shift
  (cd "$install_dir" && COMPOSE_IGNORE_ORPHANS=True docker compose "$@")
}

preserve_existing_files() {
  local install_dir="$1"
  local ts
  local file
  ts="$(timestamp)"

  for file in config.yaml docker-compose.yml; do
    if [ -f "$install_dir/$file" ]; then
      cp -a "$install_dir/$file" "$install_dir/$file.bak.$ts"
      log "已保留原文件副本 $install_dir/$file -> $install_dir/$file.bak.$ts"
    fi
  done
}

write_config_yaml() {
  local install_dir="$1"
  local api_key="$2"
  local mgt_key="$3"
  local api_key_yaml
  local mgt_key_yaml

  api_key_yaml="$(yaml_escape_double "$api_key")"
  mgt_key_yaml="$(yaml_escape_double "$mgt_key")"

  cat > "$install_dir/config.yaml" <<EOF
host: ""
port: 8317
auth-dir: "/root/.cli-proxy-api"

api-keys:
  - "$api_key_yaml"

remote-management:
  allow-remote: true
  secret-key: "$mgt_key_yaml"
  disable-control-panel: false

debug: false
logging-to-file: true
logs-max-total-size-mb: 1024
usage-statistics-enabled: true
request-retry: 3
max-retry-interval: 30

quota-exceeded:
  switch-project: true
  switch-preview-model: true
  antigravity-credits: true

ws-auth: true
redis-usage-queue-retention-seconds: 60
disable-image-generation: chat

codex-header-defaults:
  user-agent: codex_cli_rs/0.114.0 (Mac OS 14.2.0; x86_64) vscode/1.111.0
EOF
}

write_compose_yaml() {
  local install_dir="$1"
  local cpa_host_port="$2"
  local cpam_host_port="$3"
  local cpamp_admin_key="$4"
  local compose_file="${5:-$install_dir/docker-compose.yml}"
  local cpamp_admin_key_yaml
  cpamp_admin_key_yaml="$(yaml_escape_double "$cpamp_admin_key")"

  cat > "$compose_file" <<EOF
services:
  cli-proxy-api:
    image: $CPA_IMAGE
    container_name: cli-proxy-api
    restart: unless-stopped
    ports:
      - "$cpa_host_port:8317"
      - "8085:8085"
      - "1455:1455"
      - "54545:54545"
      - "51121:51121"
      - "11451:11451"
    volumes:
      - ./config.yaml:/CLIProxyAPI/config.yaml
      - ./auths:/root/.cli-proxy-api
      - ./logs:/CLIProxyAPI/logs

  cpa-manager-plus:
    image: $CPAM_IMAGE
    container_name: cpa-manager-plus
    restart: unless-stopped
    depends_on:
      - cli-proxy-api
    ports:
      - "$cpam_host_port:18317"
    environment:
      HTTP_ADDR: "0.0.0.0:18317"
      USAGE_DATA_DIR: "/data"
      USAGE_DB_PATH: "/data/usage.sqlite"
      CPA_MANAGER_DATA_KEY_PATH: "/data/data.key"
      CPA_MANAGER_ADMIN_KEY: "$cpamp_admin_key_yaml"
      USAGE_COLLECTOR_MODE: "auto"
      USAGE_BATCH_SIZE: "100"
      USAGE_POLL_INTERVAL_MS: "500"
      USAGE_QUERY_LIMIT: "50000"
      USAGE_CORS_ORIGINS: "*"
    volumes:
      - ./cpa-manager-data:/data
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:18317/health"]
      interval: 10s
      timeout: 3s
      retries: 3
EOF
}

write_secrets() {
  local install_dir="$1"
  local api_key="$2"
  local mgt_key="$3"
  local cpa_host_port="$4"
  local cpam_host_port="$5"
  local server_ip="$6"
  local cpamp_admin_key="$7"
  local secrets_file="$install_dir/.secrets.txt"

  cat > "$secrets_file" <<EOF
API_KEY=$api_key
MGT_KEY=$mgt_key
CPAMP_ADMIN_KEY=$cpamp_admin_key
CPA_API=http://$server_ip:$cpa_host_port/v1
CPA_MANAGER=http://$server_ip:$cpam_host_port/management.html
CPAMP_MANAGER=http://$server_ip:$cpam_host_port/management.html
CPA_MANAGER_SETUP_UPSTREAM=$CPA_MANAGER_SETUP_UPSTREAM
EOF
  chmod 600 "$secrets_file"
}

handle_firewall() {
  local cpa_host_port="$1"
  local cpam_host_port="$2"
  local ports=("$cpa_host_port" "$cpam_host_port" 8085 1455 54545 51121 11451)
  local port

  command -v ufw >/dev/null 2>&1 || return 0

  if ufw status 2>/dev/null | grep -qw "active"; then
    log "UFW 已启用，自动放行 CPA / CPA Manager Plus 相关端口"
    for port in "${ports[@]}"; do
      ufw allow "${port}/tcp"
    done
    warn "请同时在云厂商安全组放行 8317/18317（或你自定义的宿主机端口）"
    return 0
  fi

  if ask_yes_no "UFW 未启用，是否启用并放行 SSH、CPA、CPA Manager Plus 相关端口" "N"; then
    ufw allow 22/tcp
    for port in "${ports[@]}"; do
      ufw allow "${port}/tcp"
    done
    ufw --force enable
    warn "请同时在云厂商安全组放行 8317/18317（或你自定义的宿主机端口）"
  else
    warn "UFW 未启用；如有云厂商安全组，请放行 8317/18317"
  fi
}

pre_install_cleanup() {
  local found=()
  local container

  for container in "$CPA_CONTAINER" "$CPAM_CONTAINER" "$LEGACY_CPAM_CONTAINER" "$OLD_PANEL_CONTAINER"; do
    if container_exists "$container"; then
      found+=("$container")
    fi
  done

  if [ "${#found[@]}" -eq 0 ]; then
    return 0
  fi

  warn "检测到已有相关容器：${found[*]}"
  show_menu_status

  if ask_yes_no "确认删除上述容器并重建" "N"; then
    docker rm -f "${found[@]}"
  else
    die "已取消安装/重装"
  fi
}

prepare_install_dir() {
  local install_dir="$1"
  mkdir -p \
    "$install_dir/auths" \
    "$install_dir/logs" \
    "$install_dir/cpa-manager-data" \
    "$install_dir/snapshots/manual" \
    "$install_dir/snapshots/system" \
    "$install_dir/snapshots/migration"
  chmod 700 \
    "$install_dir/snapshots" \
    "$install_dir/snapshots/manual" \
    "$install_dir/snapshots/system" \
    "$install_dir/snapshots/migration"
}

# -----------------------------------------------------------------------------
# 快照、健康检查与迁移校验
# -----------------------------------------------------------------------------

create_snapshot_archive() {
  local install_dir="$1"
  local backup_file="$2"
  shift 2
  local items=()
  local item

  mkdir -p "$(dirname "$backup_file")"
  for item in "$@"; do
    if [ -e "$install_dir/$item" ]; then
      items+=("$item")
    fi
  done

  if [ "${#items[@]}" -eq 0 ]; then
    warn "没有可写入快照归档的文件"
    return 0
  fi

  if ! (cd "$install_dir" && tar -czf "$backup_file" "${items[@]}"); then
    rm -f "$backup_file"
    return 1
  fi
  log "归档创建完成: $backup_file"
}

# 在不中断服务的情况下保存配置、凭证，并使用 SQLite 在线备份 API 生成一致的数据快照。
create_online_snapshot_archive() {
  local install_dir="$1"
  local backup_file="$2"
  local python_bin="${PYTHON_BIN:-python3}"
  local staging_dir
  local item
  local source_db="$install_dir/cpa-manager-data/usage.sqlite"
  local target_db

  mkdir -p "$(dirname "$backup_file")" "$install_dir/snapshots"
  chmod 700 "$install_dir/snapshots"
  staging_dir="$(mktemp -d "$install_dir/snapshots/.creating-online.XXXXXX")"
  mkdir -p "$staging_dir/cpa-manager-data"

  for item in docker-compose.yml config.yaml .secrets.txt auths; do
    if [ -e "$install_dir/$item" ]; then
      cp -a "$install_dir/$item" "$staging_dir/" || {
        rm -rf "$staging_dir"
        return 1
      }
    fi
  done

  if [ -d "$install_dir/cpa-manager-data" ]; then
    while IFS= read -r -d '' item; do
      cp -a "$item" "$staging_dir/cpa-manager-data/" || {
        rm -rf "$staging_dir"
        return 1
      }
    done < <(find "$install_dir/cpa-manager-data" -mindepth 1 -maxdepth 1 \
      ! -name 'usage.sqlite' ! -name 'usage.sqlite-wal' ! -name 'usage.sqlite-shm' -print0 2>/dev/null)
  fi

  if [ -s "$source_db" ]; then
    target_db="$staging_dir/cpa-manager-data/usage.sqlite"
    if ! "$python_bin" - "$source_db" "$target_db" <<'PY'
import sqlite3
import sys

source_path, target_path = sys.argv[1], sys.argv[2]
source = sqlite3.connect(f"file:{source_path}?mode=ro", uri=True, timeout=30)
target = sqlite3.connect(target_path)
try:
    source.backup(target)
    result = target.execute("PRAGMA quick_check").fetchone()
    if not result or result[0] != "ok":
        raise RuntimeError(f"SQLite quick_check failed: {result}")
finally:
    target.close()
    source.close()
PY
    then
      warn "Manager SQLite 在线快照失败"
      rm -rf "$staging_dir"
      return 1
    fi
  else
    warn "未找到 Manager SQLite，快速快照将只包含配置和凭证"
  fi

  cat > "$staging_dir/SNAPSHOT-MANIFEST.txt" <<EOF
快照模式：快速不停机快照
创建时间：$(date -Iseconds)
强一致内容：Manager SQLite 在线快照
尽力快照内容：Compose、配置、密钥和认证文件
未包含内容：运行日志
说明：服务在创建快照期间保持运行，后续新增数据由下一次快照继续覆盖。
EOF

  if ! tar -C "$staging_dir" -czf "$backup_file" .; then
    rm -f "$backup_file"
    rm -rf "$staging_dir"
    return 1
  fi
  rm -rf "$staging_dir"
  verify_snapshot_archive "$backup_file" || {
    rm -f "$backup_file"
    return 1
  }
  log "快速不停机快照完成: $backup_file"
}

# Manager 运行时会持续写入 SQLite。创建一致性快照前短暂停止 Manager，并在任何结果下恢复原运行状态。
create_consistent_snapshot_archive() {
  local install_dir="$1"
  local backup_file="$2"
  local scope="$3"
  shift 3
  local manager_container
  local running_containers=()
  local container
  local backup_ok="true"
  local restart_ok="true"

  manager_container="$(active_cpam_container)"
  if container_exists "$manager_container" &&
     [ "$(docker inspect -f '{{.State.Running}}' "$manager_container" 2>/dev/null || true)" = "true" ]; then
    running_containers+=("$manager_container")
    log "暂停 $manager_container 以创建一致性快照"
    docker stop "$manager_container" >/dev/null || return 1
  fi

  if [ "$scope" = "all" ] && container_exists "$CPA_CONTAINER" &&
     [ "$(docker inspect -f '{{.State.Running}}' "$CPA_CONTAINER" 2>/dev/null || true)" = "true" ]; then
    log "暂停 $CPA_CONTAINER 以冻结认证和日志数据"
    if ! docker stop "$CPA_CONTAINER" >/dev/null; then
      for container in "${running_containers[@]}"; do
        docker start "$container" >/dev/null 2>&1 || true
      done
      return 1
    fi
    running_containers+=("$CPA_CONTAINER")
  fi

  if ! create_snapshot_archive "$install_dir" "$backup_file" "$@"; then
    backup_ok="false"
  elif ! verify_snapshot_archive "$backup_file"; then
    rm -f "$backup_file"
    backup_ok="false"
  fi

  for (( container=${#running_containers[@]}-1; container>=0; container-- )); do
    if docker start "${running_containers[$container]}" >/dev/null; then
      log "${running_containers[$container]} 已恢复运行"
    else
      restart_ok="false"
      err "${running_containers[$container]} 恢复启动失败，请立即手动启动"
    fi
  done

  [ "$backup_ok" = "true" ] && [ "$restart_ok" = "true" ]
}

# 快照目录按用途隔离：manual 为用户创建，system 为脚本自动保护点，migration 为迁移专用。
snapshot_root_dir() {
  local install_dir="$1"
  printf '%s/snapshots\n' "$install_dir"
}

sanitize_snapshot_remark() {
  local remark="$1"
  printf '%s' "$remark" | tr '\r\n\t' '   ' | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177'
}

snapshot_metadata_value() {
  local metadata_file="$1"
  local key="$2"
  awk -F= -v key="$key" 'index($0, key "=") == 1 { sub(/^[^=]*=/, ""); print; exit }' "$metadata_file" 2>/dev/null
}

# 校验人工快照、系统保护点和迁移快照共用的元数据及主归档。
# 旧版本 metadata.env 仍允许读取，只要包含原有 archive/checksum_sha256 字段。
validate_snapshot_metadata() {
  local metadata_file="$1"
  local snapshot_dir
  local archive_name
  local checksum_sha256
  local actual_checksum
  local format_version

  [ -s "$metadata_file" ] || return 1
  snapshot_dir="$(dirname "$metadata_file")"
  format_version="$(snapshot_metadata_value "$metadata_file" format_version)"
  case "$format_version" in
    2|3) ;;
    *) return 1 ;;
  esac
  archive_name="$(snapshot_metadata_value "$metadata_file" archive)"
  checksum_sha256="$(snapshot_metadata_value "$metadata_file" checksum_sha256)"
  [ -n "$archive_name" ] && [[ "$archive_name" != */* ]] || return 1
  [ -s "$snapshot_dir/$archive_name" ] || return 1
  [[ "$checksum_sha256" =~ ^[[:xdigit:]]{64}$ ]] || return 1
  actual_checksum="$(sha256sum "$snapshot_dir/$archive_name" | awk '{print $1}')"
  [ "$actual_checksum" = "$checksum_sha256" ]
}

human_file_size() {
  local bytes="$1"
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || printf '%s B' "$bytes"
  else
    awk -v bytes="$bytes" 'BEGIN {
      split("B KiB MiB GiB TiB", unit, " "); i=1;
      while (bytes >= 1024 && i < 5) { bytes /= 1024; i++ }
      if (i == 1) printf "%d %s", bytes, unit[i]; else printf "%.1f %s", bytes, unit[i]
    }'
  fi
}

CREATED_SNAPSHOT_DIR=""

# 所有人工快照、系统保护点和迁移保护点共用同一版元数据与校验字段。
write_snapshot_metadata() {
  local snapshot_dir="$1"
  local snapshot_id="$2"
  local category="$3"
  local mode="$4"
  local remark="$5"
  local archive_name="$6"
  local install_dir="$7"
  local contents="$8"
  local restore_scope="$9"
  local archive_file="$snapshot_dir/$archive_name"
  local size_bytes
  local checksum_sha256
  local cpa_host_port
  local manager_host_port
  local protection_point

  [ -s "$archive_file" ] || return 1
  size_bytes="$(wc -c < "$archive_file" | tr -d ' ')"
  checksum_sha256="$(sha256sum "$archive_file" | awk '{print $1}')"
  remark="$(sanitize_snapshot_remark "$remark")"
  collect_runtime_status "$install_dir"
  cpa_host_port="$RUNTIME_CPA_HOST_PORT"
  manager_host_port="$RUNTIME_MANAGER_HOST_PORT"
  protection_point="false"
  if [ "$category" = "system" ] || [ "$category" = "migration" ]; then
    protection_point="true"
  fi
  cat > "$snapshot_dir/metadata.env" <<EOF
format_version=3
snapshot_id=$snapshot_id
category=$category
snapshot_type=$category
mode=$mode
reason=$snapshot_id
trigger=$snapshot_id
protection_point=$protection_point
created_at=$(date -Iseconds)
size_bytes=$size_bytes
checksum_sha256=$checksum_sha256
primary_archive=$archive_name
primary_size_bytes=$size_bytes
primary_checksum_sha256=$checksum_sha256
artifacts=primary:$archive_name
remark=$remark
description=$remark
script_version=$SCRIPT_VERSION
install_dir=$install_dir
cpa_host_port=$cpa_host_port
manager_host_port=$manager_host_port
cpa_image=${RUNTIME_CPA_IMAGE:-$CPA_IMAGE}
cpa_image_id=$RUNTIME_CPA_IMAGE_ID
manager_image=${RUNTIME_PLUS_IMAGE:-${RUNTIME_LEGACY_IMAGE:-$CPAM_IMAGE}}
manager_image_id=${RUNTIME_PLUS_IMAGE_ID:-$RUNTIME_LEGACY_IMAGE_ID}
target_manager_image=$CPAM_IMAGE
contents=$contents
restore_scope=$restore_scope
archive=$archive_name
EOF
  chmod 600 "$snapshot_dir/metadata.env" "$archive_file"
}

append_secondary_snapshot_archive() {
  local metadata_file="$1"
  local archive_file="$2"
  local prefix="$3"
  local size_bytes
  local checksum_sha256

  [ -f "$metadata_file" ] && [ -s "$archive_file" ] || return 1
  size_bytes="$(wc -c < "$archive_file" | tr -d ' ')"
  checksum_sha256="$(sha256sum "$archive_file" | awk '{print $1}')"
  cat >> "$metadata_file" <<EOF
${prefix}_archive=$(basename "$archive_file")
${prefix}_size_bytes=$size_bytes
${prefix}_checksum_sha256=$checksum_sha256
artifact_${prefix}_archive=$(basename "$archive_file")
artifact_${prefix}_size_bytes=$size_bytes
artifact_${prefix}_checksum_sha256=$checksum_sha256
artifacts_append=${prefix}:$(basename "$archive_file")
EOF
}

# 创建带独立目录和元数据的标准快照，供人工、安装、升级和恢复保护共同复用。
create_snapshot_record() {
  local install_dir="$1"
  local category="$2"
  local label="$3"
  local remark="$4"
  local mode="$5"
  local root
  local snapshot_id
  local final_dir
  local temp_dir
  local archive_file
  local suffix=0

  case "$category" in
    manual|system) ;;
    *) warn "未知快照分类: $category"; return 1 ;;
  esac
  case "$mode" in
    online|consistent) ;;
    *) warn "未知快照模式: $mode"; return 1 ;;
  esac

  root="$(snapshot_root_dir "$install_dir")"
  mkdir -p "$root/$category"
  chmod 700 "$root" "$root/$category"
  snapshot_id="${label}-$(timestamp)"
  final_dir="$root/$category/$snapshot_id"
  while [ -e "$final_dir" ]; do
    suffix=$((suffix + 1))
    final_dir="$root/$category/${snapshot_id}-${suffix}"
  done
  temp_dir="$root/$category/.creating-$(basename "$final_dir").$$"
  mkdir -p "$temp_dir"
  archive_file="$temp_dir/snapshot.tar.gz"

  if [ "$mode" = "online" ]; then
    if ! create_online_snapshot_archive "$install_dir" "$archive_file"; then
      rm -rf "$temp_dir"
      return 1
    fi
  else
    if ! create_consistent_snapshot_archive "$install_dir" "$archive_file" all \
      docker-compose.yml config.yaml .secrets.txt auths cpa-manager-data; then
      rm -rf "$temp_dir"
      return 1
    fi
  fi

  write_snapshot_metadata "$temp_dir" "$(basename "$final_dir")" "$category" "$mode" "$remark" \
    snapshot.tar.gz "$install_dir" "compose,config,secrets,auths,manager-data" "managed-deployment" || {
    rm -rf "$temp_dir"
    return 1
  }
  mv "$temp_dir" "$final_dir"
  CREATED_SNAPSHOT_DIR="$final_dir"
  log "快照已保存: $final_dir"
}

SNAPSHOT_DIRS=()

# 收集并格式化快照列表；按元数据修改时间倒序展示，避免信息堆叠。
collect_and_print_snapshots() {
  local install_dir="$1"
  local root
  local metadata_file
  local snapshot_dir
  local category
  local category_label
  local mode
  local mode_label
  local created_at
  local display_time
  local size_bytes
  local display_size
  local remark
  local archive_name
  local status_icon
  local index=0

  root="$(snapshot_root_dir "$install_dir")"
  SNAPSHOT_DIRS=()
  print_section "现有快照"
  printf '%-4s %-8s %-19s %-10s %-10s %-32s %s\n' '编号' '类型' '创建时间' '模式' '大小' '备注' '状态'
  printf '%s\n' '────────────────────────────────────────────────────────────────────────────────────'

  while IFS= read -r metadata_file; do
    [ -f "$metadata_file" ] || continue
    snapshot_dir="$(dirname "$metadata_file")"
    category="$(snapshot_metadata_value "$metadata_file" category)"
    mode="$(snapshot_metadata_value "$metadata_file" mode)"
    created_at="$(snapshot_metadata_value "$metadata_file" created_at)"
    size_bytes="$(snapshot_metadata_value "$metadata_file" size_bytes)"
    remark="$(snapshot_metadata_value "$metadata_file" remark)"
    archive_name="$(snapshot_metadata_value "$metadata_file" archive)"
    [ -n "$archive_name" ] || archive_name="snapshot.tar.gz"
    [ -n "$size_bytes" ] || size_bytes="$(wc -c < "$snapshot_dir/$archive_name" 2>/dev/null | tr -d ' ' || printf '0')"
    if validate_snapshot_metadata "$metadata_file"; then
      status_icon="$ICON_OK"
    else
      status_icon="$ICON_ERROR"
    fi

    case "$category" in
      manual) category_label="人工" ;;
      system) category_label="系统" ;;
      *) category_label="未知" ;;
    esac
    case "$mode" in
      online) mode_label="不停机" ;;
      consistent) mode_label="一致性" ;;
      *) mode_label="未知" ;;
    esac
    display_time="${created_at%%+*}"
    display_time="${display_time/T/ }"
    display_time="${display_time:0:19}"
    display_size="$(human_file_size "$size_bytes")"
    [ -n "$remark" ] || remark="（无备注）"
    if [ "${#remark}" -gt 32 ]; then
      remark="${remark:0:29}..."
    fi

    index=$((index + 1))
    SNAPSHOT_DIRS+=("$snapshot_dir")
    printf '%-4s %-8s %-19s %-10s %-10s %-32s %b\n' "$index" "$category_label" "$display_time" "$mode_label" "$display_size" "$remark" "$status_icon"
  done < <(find "$root/manual" "$root/system" -mindepth 2 -maxdepth 2 -type f -name metadata.env \
    -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)

  if [ "$index" -eq 0 ]; then
    printf '%b  暂无可用快照。%b\n' "$ICON_WARN" "$COLOR_RESET"
  else
    printf '%s\n' '────────────────────────────────────────────────────────────────────────────────────'
    printf '共 %s 个快照；文件目录：%s\n' "$index" "$root"
  fi
}

list_snapshots() {
  local install_dir
  install_dir="$(detect_install_dir)"
  collect_and_print_snapshots "$install_dir"
}

is_managed_snapshot_dir() {
  local install_dir="$1"
  local snapshot_dir="$2"
  local root
  local resolved_root
  local resolved_dir

  root="$(snapshot_root_dir "$install_dir")"
  resolved_root="$(readlink -f "$root" 2>/dev/null || true)"
  resolved_dir="$(readlink -f "$snapshot_dir" 2>/dev/null || true)"
  [ -n "$resolved_root" ] && [ -n "$resolved_dir" ] || return 1
  [ ! -L "$snapshot_dir" ] || return 1
  case "$resolved_dir" in
    "$resolved_root/manual/"*|"$resolved_root/system/"*) ;;
    *) return 1 ;;
  esac
  [ -f "$resolved_dir/metadata.env" ] && [ -f "$resolved_dir/snapshot.tar.gz" ]
}

snapshot_can_be_deleted() {
  local category="$1"
  local snapshot_id="$2"

  if [ "$category" = "manual" ]; then
    return 0
  fi
  if [ "$category" = "system" ] && [[ "$snapshot_id" == scheduled-* ]]; then
    return 0
  fi
  return 1
}

delete_snapshot() {
  local install_dir
  local selection
  local snapshot_dir
  local metadata_file
  local snapshot_id
  local category
  local created_at
  local remark
  local display_size

  install_dir="$(detect_install_dir)"
  collect_and_print_snapshots "$install_dir"
  [ "${#SNAPSHOT_DIRS[@]}" -gt 0 ] || return 0
  selection="$(read_with_default "请输入要删除的快照编号，回车取消: " "")"
  [ -n "$selection" ] || { log "已取消删除"; return 0; }
  [[ "$selection" =~ ^[0-9]+$ ]] || die "快照编号必须是数字"
  (( selection >= 1 && selection <= ${#SNAPSHOT_DIRS[@]} )) || die "快照编号超出范围"

  snapshot_dir="${SNAPSHOT_DIRS[$((selection - 1))]}"
  is_managed_snapshot_dir "$install_dir" "$snapshot_dir" || die "目标不是受管快照目录，拒绝删除: $snapshot_dir"
  metadata_file="$snapshot_dir/metadata.env"
  snapshot_id="$(snapshot_metadata_value "$metadata_file" snapshot_id)"
  category="$(snapshot_metadata_value "$metadata_file" category)"
  created_at="$(snapshot_metadata_value "$metadata_file" created_at)"
  remark="$(snapshot_metadata_value "$metadata_file" remark)"
  snapshot_can_be_deleted "$category" "$snapshot_id" || die "该快照是系统保护点，不能通过普通删除入口删除: $snapshot_id"
  display_size="$(human_file_size "$(snapshot_metadata_value "$metadata_file" size_bytes)")"

  print_section "删除快照确认"
  printf '快照 ID：%s\n' "$snapshot_id"
  printf '类型：%s\n' "$category"
  printf '创建时间：%s\n' "$created_at"
  printf '大小：%s\n' "$display_size"
  printf '备注：%s\n' "${remark:-（无备注）}"
  printf '影响：只删除该快照目录，不影响当前部署、其他快照或原始日志。\n'
  if ! ask_yes_no "确认永久删除这个快照" "N"; then
    log "已取消删除"
    return 0
  fi
  rm -rf "${snapshot_dir:?}"
  log "已删除快照: $snapshot_id"
}

# 滚动清理只处理 scheduled-*，系统初始点、升级前和恢复前保护点永远不自动删除。
prune_scheduled_snapshots() {
  local install_dir="$1"
  local keep_count="$2"
  local system_dir
  local metadata_file
  local snapshot_dir
  local index=0

  [[ "$keep_count" =~ ^[0-9]+$ ]] && (( keep_count >= 1 )) || return 1
  system_dir="$(snapshot_root_dir "$install_dir")/system"
  while IFS= read -r metadata_file; do
    index=$((index + 1))
    (( index <= keep_count )) && continue
    snapshot_dir="$(dirname "$metadata_file")"
    is_managed_snapshot_dir "$install_dir" "$snapshot_dir" || {
      warn "跳过非受管定时快照目录: $snapshot_dir"
      continue
    }
    rm -rf "${snapshot_dir:?}"
    log "滚动删除旧定时快照: $(basename "$snapshot_dir")"
  done < <(find "$system_dir" -mindepth 2 -maxdepth 2 -type f -name metadata.env -path '*/scheduled-*/metadata.env' \
    -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
}

run_scheduled_snapshot() {
  local install_dir
  local schedule_file
  local keep_count="10"

  install_dir="$(detect_install_dir)"
  ensure_compose_dir "$install_dir"
  mkdir -p "$install_dir/state"
  chmod 700 "$install_dir/state"
  schedule_file="$install_dir/state/task-center.env"
  [ -f "$schedule_file" ] || schedule_file="$install_dir/state/snapshot-schedule.env"
  if [ -f "$schedule_file" ]; then
    keep_count="$(awk -F= '$1 == "KEEP_COUNT" { print $2; exit }' "$schedule_file")"
  fi
  [[ "$keep_count" =~ ^[0-9]+$ ]] && (( keep_count >= 1 )) || keep_count="10"

  exec 9> "$install_dir/state/snapshot.lock"
  if command -v flock >/dev/null 2>&1 && ! flock -n 9; then
    warn "已有快照任务正在运行，本次定时任务跳过"
    return 0
  fi
  create_snapshot_record "$install_dir" system scheduled "自动定时快照" online || return 1
  prune_scheduled_snapshots "$install_dir" "$keep_count"
}

run_scheduled_version_check() {
  local install_dir="${INSTALL_DIR:-$(detect_install_dir)}"
  local report_file="$install_dir/state/version-check.latest.txt"
  local result=0

  mkdir -p "$install_dir/state"
  chmod 700 "$install_dir/state"
  exec 9> "$install_dir/state/version-check.lock"
  if command -v flock >/dev/null 2>&1 && ! flock -n 9; then
    warn "已有版本检查任务正在运行，本次任务跳过"
    return 0
  fi
  if check_available_versions >"$report_file" 2>&1; then
    result=0
  else
    result=$?
    [ "$result" -eq 10 ] || result=1
  fi
  chmod 600 "$report_file"
  cat "$report_file"
  if [ "$result" -eq 10 ]; then
    warn "发现可用新镜像；仅记录结果，不会自动升级"
    return 0
  fi
  return "$result"
}

configure_task_center() {
  local install_dir
  local frequency
  local on_calendar
  local keep_count
  local enable_version
  local enable_snapshot
  local managed_script
  local source_script="${BASH_SOURCE[0]}"
  local snapshot_service="/etc/systemd/system/cpa-cpam-snapshot.service"
  local snapshot_timer="/etc/systemd/system/cpa-cpam-snapshot.timer"
  local version_service="/etc/systemd/system/cpa-cpam-version.service"
  local version_timer="/etc/systemd/system/cpa-cpam-version.timer"

  has_systemd || die "当前系统没有可用 systemd，无法配置计划任务中心"
  install_dir="$(detect_install_dir)"
  ensure_compose_dir "$install_dir"
  [[ "$install_dir" != *$'\n'* && "$install_dir" != *$'\r'* && ! "$install_dir" =~ [\"%] ]] || die "安装目录包含不适合 systemd 单元的字符"
  print_section "计划任务中心"
  printf '1) 每天 03:00\n'
  printf '2) 每周日 03:00\n'
  frequency="$(read_with_default "请选择执行频率 [1]: " "1")"
  case "$frequency" in
    1) on_calendar="*-*-* 03:00:00" ;;
    2) on_calendar="Sun *-*-* 03:00:00" ;;
    *) die "无效执行频率: $frequency" ;;
  esac
  keep_count="$(read_with_default "定时快照保留数量 [10]: " "10")"
  [[ "$keep_count" =~ ^[0-9]+$ ]] && (( keep_count >= 1 && keep_count <= 100 )) || die "保留数量必须是 1-100"
  enable_version="$(read_with_default "启用定时版本检查？[Y/n]: " "Y")"
  enable_snapshot="$(read_with_default "启用定时快照？[Y/n]: " "Y")"
  [[ "$enable_version" =~ ^[Yy]([Ee][Ss])?$|^$ ]] && enable_version="true" || enable_version="false"
  [[ "$enable_snapshot" =~ ^[Yy]([Ee][Ss])?$|^$ ]] && enable_snapshot="true" || enable_snapshot="false"
  [ "$enable_version" = "true" ] || [ "$enable_snapshot" = "true" ] || die "至少启用一个计划任务"

  print_section "计划任务确认"
  printf '安装目录：%s\n' "$install_dir"
  printf '执行计划：%s\n' "$on_calendar"
  printf '定时版本检查：%s（只读拉取并比较镜像，不自动升级）\n' "$([ "$enable_version" = "true" ] && printf '启用' || printf '停用')"
  printf '定时快照：%s（不停机，保留最近 %s 个 scheduled-*）\n' "$([ "$enable_snapshot" = "true" ] && printf '启用' || printf '停用')" "$keep_count"
  if ! ask_yes_no "确认写入并启用计划任务中心" "N"; then
    log "已取消计划任务中心设置"
    return 0
  fi

  mkdir -p "$install_dir/bin" "$install_dir/state"
  chmod 700 "$install_dir/bin" "$install_dir/state"
  managed_script="$install_dir/bin/cpa-cpam-manager.sh"
  cp "$source_script" "$managed_script" || die "无法安装计划任务脚本副本"
  chmod 700 "$managed_script"
  cat > "$install_dir/state/task-center.env" <<EOF
ON_CALENDAR=$on_calendar
KEEP_COUNT=$keep_count
VERSION_ENABLED=$enable_version
SNAPSHOT_ENABLED=$enable_snapshot
EOF
  chmod 600 "$install_dir/state/task-center.env"

  systemctl disable --now cpa-cpam-snapshot.timer cpa-cpam-version.timer >/dev/null 2>&1 || true
  rm -f "$snapshot_service" "$snapshot_timer" "$version_service" "$version_timer"
  if [ "$enable_snapshot" = "true" ]; then
    cat > "$snapshot_service" <<EOF
[Unit]
Description=CPA Manager Plus scheduled snapshot
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
Environment="INSTALL_DIR=$install_dir"
ExecStart=/bin/bash "$managed_script" scheduled-snapshot
EOF
    cat > "$snapshot_timer" <<EOF
[Unit]
Description=CPA Manager Plus scheduled snapshot timer

[Timer]
OnCalendar=$on_calendar
Persistent=true
RandomizedDelaySec=300
Unit=cpa-cpam-snapshot.service

[Install]
WantedBy=timers.target
EOF
  fi
  if [ "$enable_version" = "true" ]; then
    cat > "$version_service" <<EOF
[Unit]
Description=CPA Manager Plus scheduled version check
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
Environment="INSTALL_DIR=$install_dir"
ExecStart=/bin/bash "$managed_script" scheduled-version-check
EOF
    cat > "$version_timer" <<EOF
[Unit]
Description=CPA Manager Plus scheduled version check timer

[Timer]
OnCalendar=$on_calendar
Persistent=true
RandomizedDelaySec=600
Unit=cpa-cpam-version.service

[Install]
WantedBy=timers.target
EOF
  fi
  systemctl daemon-reload
  [ "$enable_snapshot" = "true" ] && systemctl enable --now cpa-cpam-snapshot.timer || true
  [ "$enable_version" = "true" ] && systemctl enable --now cpa-cpam-version.timer || true
  log "计划任务中心已更新"
  systemctl list-timers cpa-cpam-snapshot.timer cpa-cpam-version.timer --no-pager 2>/dev/null || true
}

configure_snapshot_schedule_legacy() {
  local install_dir
  local frequency
  local on_calendar
  local keep_count
  local managed_script
  local source_script="${BASH_SOURCE[0]}"
  local service_file="/etc/systemd/system/cpa-cpam-snapshot.service"
  local timer_file="/etc/systemd/system/cpa-cpam-snapshot.timer"

  has_systemd || die "当前系统没有可用 systemd，无法配置定时快照"
  install_dir="$(detect_install_dir)"
  ensure_compose_dir "$install_dir"
  [[ "$install_dir" != *$'\n'* && "$install_dir" != *$'\r'* && ! "$install_dir" =~ [\"%] ]] || die "安装目录包含不适合 systemd 单元的字符"
  print_section "定时快照设置"
  printf '1) 每天 03:00 创建\n'
  printf '2) 每周日 03:00 创建\n'
  frequency="$(read_with_default "请选择执行频率 [1]: " "1")"
  case "$frequency" in
    1) on_calendar="*-*-* 03:00:00" ;;
    2) on_calendar="Sun *-*-* 03:00:00" ;;
    *) die "无效执行频率: $frequency" ;;
  esac
  keep_count="$(read_with_default "保留最近多少个自动定时快照 [10]: " "10")"
  if [[ ! "$keep_count" =~ ^[0-9]+$ ]] || (( keep_count < 1 || keep_count > 100 )); then
    die "保留数量必须是 1-100"
  fi

  print_section "启用定时快照确认"
  printf '安装目录：%s\n' "$install_dir"
  printf '执行计划：%s\n' "$on_calendar"
  printf '快照模式：快速不停机\n'
  printf '滚动策略：只保留最近 %s 个 scheduled-* 快照\n' "$keep_count"
  printf '不会自动删除：人工快照、初始安装、升级前、密钥重置前、恢复前和迁移快照。\n'
  if ! ask_yes_no "确认写入并启用 systemd timer" "N"; then
    log "已取消定时快照设置"
    return 0
  fi

  mkdir -p "$install_dir/bin" "$install_dir/state"
  chmod 700 "$install_dir/bin" "$install_dir/state"
  managed_script="$install_dir/bin/cpa-cpam-manager.sh"
  cp "$source_script" "$managed_script" || die "无法安装定时任务脚本副本"
  chmod 700 "$managed_script"
  cat > "$install_dir/state/snapshot-schedule.env" <<EOF
KEEP_COUNT=$keep_count
ON_CALENDAR=$on_calendar
EOF
  chmod 600 "$install_dir/state/snapshot-schedule.env"
  cat > "$service_file" <<EOF
[Unit]
Description=CPA Manager Plus automatic snapshot
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
Environment="INSTALL_DIR=$install_dir"
ExecStart=/bin/bash "$managed_script" scheduled-snapshot
EOF
  cat > "$timer_file" <<EOF
[Unit]
Description=CPA Manager Plus automatic snapshot timer

[Timer]
OnCalendar=$on_calendar
Persistent=true
RandomizedDelaySec=300
Unit=cpa-cpam-snapshot.service

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now cpa-cpam-snapshot.timer
  log "定时快照已启用"
  systemctl list-timers cpa-cpam-snapshot.timer --no-pager || true
}

remove_snapshot_schedule() {
  local service_file="/etc/systemd/system/cpa-cpam-snapshot.service"
  local timer_file="/etc/systemd/system/cpa-cpam-snapshot.timer"
  local version_service="/etc/systemd/system/cpa-cpam-version.service"
  local version_timer="/etc/systemd/system/cpa-cpam-version.timer"

  if has_systemd && { [ -f "$service_file" ] || [ -f "$timer_file" ] || [ -f "$version_service" ] || [ -f "$version_timer" ]; }; then
    systemctl disable --now cpa-cpam-snapshot.timer >/dev/null 2>&1 || true
    systemctl disable --now cpa-cpam-version.timer >/dev/null 2>&1 || true
    rm -f "$service_file" "$timer_file" "$version_service" "$version_timer"
    systemctl daemon-reload >/dev/null 2>&1 || true
    log "已移除定时快照 systemd timer"
  fi
}

# 兼容旧命令名称；新的配置入口统一称为计划任务中心。
configure_snapshot_schedule() {
  configure_task_center
}

create_snapshot() {
  local install_dir
  local mode_choice
  local mode
  local remark

  install_dir="$(detect_install_dir)"
  ensure_compose_dir "$install_dir"
  remark="$(read_with_default "快照备注（可直接回车跳过）: " "")"
  print_section "选择快照模式"
  printf '1) 快速不停机（默认）  配置、凭证和 SQLite 时间点快照，不包含日志\n'
  printf '2) 完整一致性          短暂停止两个服务，适合重大变更前保护\n'
  mode_choice="$(read_with_default "请选择 [1]: " "1")"
  case "$mode_choice" in
    1) mode="online" ;;
    2) mode="consistent" ;;
    *) warn "无效快照模式: $mode_choice"; return 1 ;;
  esac

  print_section "创建快照确认"
  printf '安装目录：%s\n' "$install_dir"
  printf '保存目录：%s/manual/\n' "$(snapshot_root_dir "$install_dir")"
  printf '快照模式：%s\n' "$([ "$mode" = "online" ] && printf '快速不停机' || printf '完整一致性')"
  printf '备注：%s\n' "${remark:-（无备注）}"
  if ! ask_yes_no "确认创建快照" "Y"; then
    log "已取消创建快照"
    return 0
  fi
  create_snapshot_record "$install_dir" manual manual "$remark" "$mode" || die "创建快照失败"
  collect_and_print_snapshots "$install_dir"
}

# 仅允许脚本自身生成的受管文件进入恢复区，拒绝路径穿越和未知顶层文件。
verify_restorable_snapshot() {
  local archive_file="$1"
  local expected_checksum="${2:-}"
  local actual_checksum
  local entry
  verify_snapshot_archive "$archive_file" || return 1
  if [ -n "$expected_checksum" ]; then
    actual_checksum="$(sha256sum "$archive_file" | awk '{print $1}')"
    [ "$actual_checksum" = "$expected_checksum" ] || return 1
  fi
  while IFS= read -r entry; do
    entry="${entry#./}"
    [ -z "$entry" ] && continue
    case "/$entry/" in
      *'/../'*) return 1 ;;
    esac
    case "$entry" in
      docker-compose.yml|config.yaml|.secrets.txt|SNAPSHOT-MANIFEST.txt|auths|auths/*|cpa-manager-data|cpa-manager-data/*) ;;
      *) warn "快照包含未知路径，已拒绝恢复: $entry"; return 1 ;;
    esac
  done < <(tar -tzf "$archive_file")
}

# 恢复后同时验证两个服务，避免“容器已启动”被误判为“数据可用”。
validate_snapshot_restore() {
  local install_dir="$1"
  local cpa_host_port
  local cpam_host_port
  local api_key
  local attempt

  collect_runtime_status "$install_dir"
  cpa_host_port="$RUNTIME_CPA_HOST_PORT"
  cpam_host_port="$RUNTIME_MANAGER_HOST_PORT"
  api_key="$(load_secrets_value "$install_dir/.secrets.txt" "API_KEY" || true)"
  for attempt in 1 2 3 4 5 6; do
    if curl -fsS --max-time 8 "http://127.0.0.1:${cpam_host_port}/health" >/dev/null 2>&1 &&
       { [ -z "$api_key" ] || curl -fsS --max-time 8 "http://127.0.0.1:${cpa_host_port}/v1/models" \
           -H "Authorization: Bearer ${api_key}" >/dev/null 2>&1; }; then
      return 0
    fi
    sleep 3
  done
  return 1
}

restore_snapshot() {
  local install_dir
  local selection
  local snapshot_dir
  local metadata_file
  local archive_file
  local snapshot_id
  local created_at
  local remark
  local checksum_sha256
  local staging_dir
  local rollback_dir
  local item
  local restore_ok="true"

  install_dir="$(detect_install_dir)"
  ensure_compose_dir "$install_dir"
  collect_and_print_snapshots "$install_dir"
  [ "${#SNAPSHOT_DIRS[@]}" -gt 0 ] || return 0
  selection="$(read_with_default "请输入要恢复的快照编号，回车取消: " "")"
  [ -n "$selection" ] || { log "已取消恢复"; return 0; }
  [[ "$selection" =~ ^[0-9]+$ ]] || die "快照编号必须是数字"
  (( selection >= 1 && selection <= ${#SNAPSHOT_DIRS[@]} )) || die "快照编号超出范围"

  snapshot_dir="${SNAPSHOT_DIRS[$((selection - 1))]}"
  metadata_file="$snapshot_dir/metadata.env"
  validate_snapshot_metadata "$metadata_file" || die "快照元数据或主归档校验失败: $metadata_file"
  archive_file="$snapshot_dir/$(snapshot_metadata_value "$metadata_file" archive)"
  snapshot_id="$(snapshot_metadata_value "$metadata_file" snapshot_id)"
  created_at="$(snapshot_metadata_value "$metadata_file" created_at)"
  remark="$(snapshot_metadata_value "$metadata_file" remark)"
  checksum_sha256="$(snapshot_metadata_value "$metadata_file" checksum_sha256)"
  verify_restorable_snapshot "$archive_file" "$checksum_sha256" || die "快照校验失败、不可读或包含不安全路径: $snapshot_dir"

  print_section "恢复快照确认"
  printf '目标快照：%s\n' "$snapshot_id"
  printf '创建时间：%s\n' "$created_at"
  printf '备注：%s\n' "${remark:-（无备注）}"
  printf '影响：CPA 与 Manager 将短暂停止；配置、凭证和 Manager 数据会回到该快照。\n'
  printf '保护措施：恢复前会自动创建一份当前状态保护快照；原始日志不会删除。\n'
  if ! ask_yes_no "已核对目标，确认恢复快照" "N"; then
    log "已取消恢复"
    return 0
  fi

  create_snapshot_record "$install_dir" system pre-restore "恢复 $snapshot_id 前自动保护" consistent || die "恢复前保护快照创建失败，已中止"
  staging_dir="$(mktemp -d "$install_dir/.restoring-snapshot.XXXXXX")"
  rollback_dir="$(mktemp -d "$install_dir/.restore-rollback.XXXXXX")"
  if ! tar -xzf "$archive_file" -C "$staging_dir"; then
    rm -rf "$staging_dir" "$rollback_dir"
    die "快照解压失败，未修改现有数据"
  fi

  docker stop "$CPA_CONTAINER" "$CPAM_CONTAINER" >/dev/null 2>&1 || true
  for item in docker-compose.yml config.yaml .secrets.txt auths cpa-manager-data; do
    if [ -e "$install_dir/$item" ]; then
      mv "$install_dir/$item" "$rollback_dir/" || restore_ok="false"
    fi
  done
  if [ "$restore_ok" = "true" ]; then
    for item in docker-compose.yml config.yaml .secrets.txt auths cpa-manager-data; do
      if [ -e "$staging_dir/$item" ]; then
        mv "$staging_dir/$item" "$install_dir/" || restore_ok="false"
      fi
    done
  fi
  if [ "$restore_ok" = "true" ]; then
    compose_in_dir "$install_dir" up -d || restore_ok="false"
  fi
  if [ "$restore_ok" = "true" ] && ! validate_snapshot_restore "$install_dir"; then
    warn "快照文件已恢复，但服务健康验证失败"
    restore_ok="false"
  fi

  if [ "$restore_ok" != "true" ]; then
    warn "恢复未完成，正在自动还原操作前文件"
    docker stop "$CPA_CONTAINER" "$CPAM_CONTAINER" >/dev/null 2>&1 || true
    for item in docker-compose.yml config.yaml .secrets.txt auths cpa-manager-data; do
      rm -rf "${install_dir:?}/$item"
      [ ! -e "$rollback_dir/$item" ] || mv "$rollback_dir/$item" "$install_dir/"
    done
    compose_in_dir "$install_dir" up -d >/dev/null 2>&1 || true
    rm -rf "$staging_dir" "$rollback_dir"
    die "恢复失败，已尝试回到操作前状态"
  fi

  rm -rf "$staging_dir" "$rollback_dir"
  log "快照恢复完成: $snapshot_id"
  show_menu_status
  health_check "$install_dir"
}

health_check() {
  local install_dir="$1"
  local api_key="${2:-}"
  local cpa_host_port="${3:-}"
  local cpam_host_port="${4:-}"
  local cpamp_admin_key
  local manager_container

  if [ -z "$cpa_host_port" ] || [ -z "$cpam_host_port" ]; then
    collect_runtime_status "$install_dir"
  fi

  if [ -z "$cpa_host_port" ]; then
    cpa_host_port="$RUNTIME_CPA_HOST_PORT"
  fi
  if [ -z "$cpam_host_port" ]; then
    cpam_host_port="$RUNTIME_MANAGER_HOST_PORT"
  fi
  if [ -z "$api_key" ]; then
    api_key="$(load_secrets_value "$install_dir/.secrets.txt" "API_KEY" || true)"
  fi

  printf 'CPA API：'
  if [ -n "$api_key" ]; then
    if curl -fsS --max-time 8 "http://127.0.0.1:${cpa_host_port}/v1/models" -H "Authorization: Bearer ${api_key}" >/dev/null 2>&1; then
      printf '%b  正常（/v1/models）\n' "$ICON_OK"
    else
      printf '%b  失败（/v1/models）\n' "$ICON_ERROR"
    fi
  else
    printf '%b  跳过，未找到 API_KEY\n' "$ICON_WARN"
  fi

  manager_container="$RUNTIME_MANAGER_CONTAINER"
  if [ "$manager_container" = "$CPAM_CONTAINER" ]; then
    printf 'Plus 健康：'
    if curl -fsS --max-time 8 "http://127.0.0.1:${cpam_host_port}/health" >/dev/null 2>&1; then
      printf '%b  正常（/health）\n' "$ICON_OK"
    else
      printf '%b  失败（/health）\n' "$ICON_ERROR"
    fi
    printf '兼容端点：'
    if curl -fsS --max-time 8 "http://127.0.0.1:${cpam_host_port}/usage-service/info" >/dev/null 2>&1; then
      printf '%b  正常（/usage-service/info）\n' "$ICON_OK"
    else
      printf '%b  失败（/usage-service/info）\n' "$ICON_ERROR"
    fi
    cpamp_admin_key="$(load_secrets_value "$install_dir/.secrets.txt" "CPAMP_ADMIN_KEY" || true)"
    printf '鉴权状态：'
    if [ -n "$cpamp_admin_key" ]; then
      if curl -fsS --max-time 8 "http://127.0.0.1:${cpam_host_port}/status" -H "Authorization: Bearer ${cpamp_admin_key}" >/dev/null 2>&1; then
        printf '%b  正常（/status）\n' "$ICON_OK"
      else
        printf '%b  失败（/status）\n' "$ICON_ERROR"
      fi
    else
      printf '%b  跳过，未找到 CPAMP_ADMIN_KEY\n' "$ICON_WARN"
    fi
  fi

  printf '管理页面：'
  if curl -fsS --max-time 8 -o /dev/null "http://127.0.0.1:${cpam_host_port}/management.html" 2>/dev/null; then
    printf '%b  可访问（/management.html）\n' "$ICON_OK"
  else
    printf '%b  无法访问（/management.html）\n' "$ICON_ERROR"
  fi
}

upsert_secrets_value() {
  local secrets_file="$1"
  local key="$2"
  local value="$3"
  local temp_file="${secrets_file}.tmp.$$"

  if [ -f "$secrets_file" ]; then
    awk -v key="$key" -v value="$value" '
      BEGIN { updated=0 }
      index($0, key "=") == 1 { print key "=" value; updated=1; next }
      { print }
      END { if (!updated) print key "=" value }
    ' "$secrets_file" > "$temp_file"
  else
    printf '%s=%s\n' "$key" "$value" > "$temp_file"
  fi
  chmod 600 "$temp_file"
  mv -f "$temp_file" "$secrets_file"
}

verify_snapshot_archive() {
  local backup_file="$1"
  [ -s "$backup_file" ] || return 1
  tar -tzf "$backup_file" >/dev/null 2>&1
}

standard_manager_data_source() {
  local install_dir="$1"
  local source
  source="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' "$LEGACY_CPAM_CONTAINER" 2>/dev/null || true)"
  [ -n "$source" ] || return 1
  [ "$(readlink -f "$source" 2>/dev/null || printf '%s' "$source")" = "$(readlink -f "$install_dir/cpa-manager-data" 2>/dev/null || printf '%s' "$install_dir/cpa-manager-data")" ] || return 1
  printf '%s\n' "$source"
}

validate_plus_migration() {
  local install_dir="$1"
  local cpam_host_port="$2"
  local cpamp_admin_key="$3"
  local attempt

  for attempt in 1 2 3 4 5 6; do
    if container_exists "$CPAM_CONTAINER" &&
       [ "$(docker inspect -f '{{.State.Running}}' "$CPAM_CONTAINER" 2>/dev/null || true)" = "true" ] &&
       curl -fsS --max-time 8 "http://127.0.0.1:${cpam_host_port}/health" >/dev/null 2>&1 &&
       curl -fsS --max-time 8 "http://127.0.0.1:${cpam_host_port}/usage-service/info" >/dev/null 2>&1 &&
       curl -fsS --max-time 8 "http://127.0.0.1:${cpam_host_port}/status" -H "Authorization: Bearer ${cpamp_admin_key}" >/dev/null 2>&1 &&
       [ -s "$install_dir/cpa-manager-data/data.key" ]; then
      return 0
    fi
    if [ "$attempt" -lt 6 ]; then
      sleep 5
    fi
  done
  return 1
}

print_install_summary() {
  local install_dir="$1"
  local api_key="$2"
  local mgt_key="$3"
  local cpa_host_port="$4"
  local cpam_host_port="$5"
  local server_ip="$6"
  local cpamp_admin_key="$7"

  cat <<EOF

安装完成

CPA API:
http://$server_ip:$cpa_host_port/v1

CPA 自带面板:
http://$server_ip:$cpa_host_port/management.html

CPA Manager Plus:
http://$server_ip:$cpam_host_port/management.html

API_KEY:
$api_key

MGT_KEY:
$mgt_key

CPAMP_ADMIN_KEY:
$cpamp_admin_key

密钥已保存到：
$install_dir/.secrets.txt

首次打开 CPA Manager Plus 如果出现 Setup，请填：
管理员密钥: $cpamp_admin_key
CPA 地址: $CPA_MANAGER_SETUP_UPSTREAM
CPA Management Key: $mgt_key
EOF
}

# -----------------------------------------------------------------------------
# 安装、升级与日常运维命令
# -----------------------------------------------------------------------------

install_cpa_cpam() {
  local install_dir_default="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
  local cpa_port_default="${CPA_HOST_PORT:-$DEFAULT_CPA_HOST_PORT}"
  local cpam_port_default="${CPAM_HOST_PORT:-$DEFAULT_CPAM_HOST_PORT}"
  local install_dir
  local cpa_host_port
  local cpam_host_port
  local api_key
  local mgt_key
  local cpamp_admin_key
  local server_ip
  local install_type

  install_type="$(detect_install_type)"
  case "$install_type" in
    legacy)
      die "检测到旧 CPA-Manager。为保护历史数据，请先运行 migration-assess 或使用菜单 17；当前版本不会通过 install 绕过迁移流程"
      ;;
    mixed)
      die "同时检测到新旧 Manager。请先确认唯一用量队列消费者，禁止安装/重装"
      ;;
  esac

  install_dir="$(read_with_default "安装目录，回车使用默认 [$install_dir_default]: " "$install_dir_default")"
  cpa_host_port="$(read_with_default "CLIProxyAPI 宿主机端口，回车使用默认 [$cpa_port_default]: " "$cpa_port_default")"
  cpam_host_port="$(read_with_default "CPA Manager Plus 宿主机端口，回车使用默认 [$cpam_port_default]: " "$cpam_port_default")"

  validate_port "$cpa_host_port" || die "CLIProxyAPI 宿主机端口无效: $cpa_host_port"
  validate_port "$cpam_host_port" || die "CPA Manager Plus 宿主机端口无效: $cpam_host_port"

  if [ -n "${API_KEY:-}" ]; then
    api_key="$(read_with_default "API_KEY，回车使用环境变量提供的值: " "${API_KEY:-}")"
  else
    api_key="$(read_with_default "API_KEY，回车使用默认 自动生成: " "")"
  fi
  if [ -z "$api_key" ]; then
    api_key="$(generate_api_key)"
  fi

  if [ -n "${MGT_KEY:-}" ]; then
    mgt_key="$(read_with_default "MGT_KEY，回车使用环境变量提供的值: " "${MGT_KEY:-}")"
  else
    mgt_key="$(read_with_default "MGT_KEY，回车使用默认 自动生成: " "")"
  fi
  if [ -z "$mgt_key" ]; then
    mgt_key="$(generate_mgt_key)"
  fi

  if [ -n "${CPAMP_ADMIN_KEY:-}" ]; then
    cpamp_admin_key="$(read_with_default "CPAMP_ADMIN_KEY，回车使用环境变量提供的值: " "${CPAMP_ADMIN_KEY:-}")"
  else
    cpamp_admin_key="$(read_with_default "CPAMP_ADMIN_KEY，回车自动生成: " "")"
  fi
  if [ -z "$cpamp_admin_key" ]; then
    cpamp_admin_key="$(generate_cpamp_admin_key)"
  fi

  if [ -d "$install_dir" ] && { [ -f "$install_dir/config.yaml" ] || [ -f "$install_dir/docker-compose.yml" ]; }; then
    print_section "重装确认"
    printf '安装目录：%s\n' "$install_dir"
    printf '影响：现有 Compose 和 config.yaml 会先保留副本再覆盖，数据目录保留。\n'
    if ! ask_yes_no "确认继续安装/重装" "N"; then
      die "已取消安装/重装"
    fi
  fi

  print_section "安装确认"
  printf '安装目录：%s\n' "$install_dir"
  printf 'CPA 端口：%s\n' "$cpa_host_port"
  printf 'Manager 端口：%s\n' "$cpam_host_port"
  printf 'CPA 镜像：%s\n' "$CPA_IMAGE"
  printf 'Manager 镜像：%s\n' "$CPAM_IMAGE"
  printf '数据策略：配置文件会保留副本后写入，auths、logs 和 cpa-manager-data 持久化。\n'
  if ! ask_yes_no "已核对安装信息，确认继续" "N"; then
    log "已取消安装"
    return 0
  fi

  pre_install_cleanup
  prepare_install_dir "$install_dir"
  preserve_existing_files "$install_dir"
  write_config_yaml "$install_dir" "$api_key" "$mgt_key"
  write_compose_yaml "$install_dir" "$cpa_host_port" "$cpam_host_port" "$cpamp_admin_key"
  server_ip="$(get_server_ip)"
  write_secrets "$install_dir" "$api_key" "$mgt_key" "$cpa_host_port" "$cpam_host_port" "$server_ip" "$cpamp_admin_key"
  handle_firewall "$cpa_host_port" "$cpam_host_port"

  log "拉取镜像并启动容器"
  compose_in_dir "$install_dir" pull || die "docker compose pull 失败"
  compose_in_dir "$install_dir" up -d || die "docker compose up -d 失败"
  sleep 8
  show_menu_status
  health_check "$install_dir" "$api_key" "$cpa_host_port" "$cpam_host_port"
  if ! create_snapshot_record "$install_dir" system initial-install "初始安装" online; then
    warn "服务已安装成功，但初始安装快照创建失败；请稍后手动创建快照"
  fi
  print_install_summary "$install_dir" "$api_key" "$mgt_key" "$cpa_host_port" "$cpam_host_port" "$server_ip" "$cpamp_admin_key"
}

upgrade_cpa_cpam() {
  local detected_dir
  local install_dir
  local install_type
  local cpa_target_ref
  local manager_target_ref
  local cpa_current_id
  local manager_current_id
  local cpa_target_id
  local manager_target_id
  local cpa_current_version
  local manager_current_version
  local cpa_target_version
  local manager_target_version
  local cpa_changed="false"
  local manager_changed="false"

  collect_runtime_status
  install_type="$RUNTIME_INSTALL_TYPE"
  case "$install_type" in
    legacy) die "检测到旧 CPA-Manager，请使用 migrate 升级到 Plus" ;;
    mixed) die "同时检测到新旧 Manager，禁止升级，请先确认唯一消费者" ;;
  esac

  detected_dir="$RUNTIME_INSTALL_DIR"
  print_section "升级检查"
  printf '安装目录：%s\n' "$detected_dir"
  install_dir="$(read_with_default "如需修改安装目录请输入新路径，直接回车继续: " "$detected_dir")"
  ensure_compose_dir "$install_dir"

  [ "$RUNTIME_CPA_EXISTS" = "true" ] || die "未检测到 $CPA_CONTAINER，无法执行升级"
  [ "$RUNTIME_PLUS_EXISTS" = "true" ] || die "未检测到 $CPAM_CONTAINER，无法执行升级"

  cpa_target_ref="$RUNTIME_CPA_IMAGE"
  manager_target_ref="$RUNTIME_PLUS_IMAGE"
  cpa_current_id="$RUNTIME_CPA_IMAGE_ID"
  manager_current_id="$RUNTIME_PLUS_IMAGE_ID"
  if [ -z "$cpa_target_ref" ] || [ -z "$manager_target_ref" ]; then
    die "无法读取当前容器镜像配置"
  fi
  if [ -z "$cpa_current_id" ] || [ -z "$manager_current_id" ]; then
    die "无法读取当前容器镜像 ID"
  fi

  printf '\n正在检查镜像仓库，请稍候...\n'
  pull_image_quietly "$cpa_target_ref" || die "CLIProxyAPI 最新镜像检查失败"
  pull_image_quietly "$manager_target_ref" || die "CPA Manager Plus 最新镜像检查失败"

  cpa_target_id="$(image_ref_id "$cpa_target_ref")"
  manager_target_id="$(image_ref_id "$manager_target_ref")"
  if [ -z "$cpa_target_id" ] || [ -z "$manager_target_id" ]; then
    die "最新镜像下载完成，但无法读取镜像 ID"
  fi

  [ "$cpa_current_id" != "$cpa_target_id" ] && cpa_changed="true"
  [ "$manager_current_id" != "$manager_target_id" ] && manager_changed="true"
  cpa_current_version="$(image_display_version "$cpa_current_id" "$cpa_target_ref")"
  manager_current_version="$(image_display_version "$manager_current_id" "$manager_target_ref")"
  cpa_target_version="$(image_display_version "$cpa_target_id" "$cpa_target_ref")"
  manager_target_version="$(image_display_version "$manager_target_id" "$manager_target_ref")"

  print_section "版本对比"
  print_upgrade_service "CLIProxyAPI" "$cpa_current_version" "$cpa_target_version" "$cpa_changed"
  printf '\n'
  print_upgrade_service "CPA Manager Plus" "$manager_current_version" "$manager_target_version" "$manager_changed"

  if [ "$cpa_changed" = "false" ] && [ "$manager_changed" = "false" ]; then
    printf '\n%b  当前两个服务均为最新镜像。%b\n' "$ICON_OK" "$COLOR_RESET"
    if ! ask_yes_no "是否仍要重新创建容器" "N"; then
      log "无需升级，已返回"
      return 0
    fi
  fi

  print_section "升级确认"
  printf '安装目录：%s\n' "$install_dir"
  printf '系统快照：升级前自动保存到 %s/system/\n' "$(snapshot_root_dir "$install_dir")"
  printf '影响范围：创建一致性快照期间 CPA 和 Manager 会短暂停止；随后重新创建容器。\n'
  printf '数据策略：保留 config.yaml、auths、日志和 cpa-manager-data。\n'
  if ! ask_yes_no "已核对版本和影响，确认开始升级" "N"; then
    log "已取消升级；已下载的镜像不会影响当前运行容器"
    return 0
  fi

  create_snapshot_record "$install_dir" system pre-upgrade "升级前自动保护" consistent || die "升级前一致性快照失败"

  log "应用已确认的镜像并重新创建服务"
  compose_in_dir "$install_dir" up -d --remove-orphans || die "docker compose up -d 失败；请使用升级前系统快照排查恢复"
  sleep 8
  show_menu_status
  health_check "$install_dir"
}

start_cpa_cpam() {
  local install_dir
  install_dir="$(detect_install_dir)"
  ensure_compose_dir "$install_dir"
  print_section "启动服务"
  printf '安装目录：%s\n' "$install_dir"
  compose_in_dir "$install_dir" up -d || die "启动失败"
  show_menu_status
}

stop_cpa_cpam() {
  local install_dir
  install_dir="$(detect_install_dir)"
  ensure_compose_dir "$install_dir"
  print_section "停止确认"
  show_menu_status
  printf '\n影响：CPA API 和 Manager 将停止对外服务，数据不会删除。\n'
  if ! ask_yes_no "确认停止全部服务" "N"; then
    log "已取消停止"
    return 0
  fi
  compose_in_dir "$install_dir" stop || die "停止失败"
  show_menu_status
}

restart_cpa_cpam() {
  local install_dir
  install_dir="$(detect_install_dir)"
  ensure_compose_dir "$install_dir"
  print_section "重启确认"
  show_menu_status
  printf '\n影响：CPA API 和 Manager 会短暂中断，数据不会删除。\n'
  if ! ask_yes_no "确认重启全部服务" "N"; then
    log "已取消重启"
    return 0
  fi
  compose_in_dir "$install_dir" restart || die "重启失败"
  show_menu_status
}

status_cpa_cpam() {
  local install_dir
  local cpa_host_port
  local cpam_host_port

  collect_runtime_status
  install_dir="$RUNTIME_INSTALL_DIR"
  cpa_host_port="$RUNTIME_CPA_HOST_PORT"
  cpam_host_port="$RUNTIME_MANAGER_HOST_PORT"

  print_section "部署信息"
  printf '安装目录：%s\n' "$install_dir"
  printf '安装类型：%s\n' "$RUNTIME_INSTALL_TYPE"
  printf 'CPA 端口：%s\n' "$cpa_host_port"
  printf 'Manager 端口：%s\n' "$cpam_host_port"
  print_section "服务状态"
  render_collected_runtime_status
  print_section "健康检查"
  health_check "$install_dir" "" "$cpa_host_port" "$cpam_host_port"
}

DOCTOR_ERRORS=0
DOCTOR_WARNINGS=0

doctor_result() {
  local level="$1"
  shift
  case "$level" in
    ok) printf '%b  %s\n' "$ICON_OK" "$*" ;;
    warn) DOCTOR_WARNINGS=$((DOCTOR_WARNINGS + 1)); printf '%b  %s\n' "$ICON_WARN" "$*" ;;
    error) DOCTOR_ERRORS=$((DOCTOR_ERRORS + 1)); printf '%b  %s\n' "$ICON_ERROR" "$*" ;;
  esac
}

# 配置体检保持只读：只解析、检查和报告，不自动覆盖配置或修改权限。
configuration_doctor() {
  local install_dir
  local cpa_port
  local manager_port
  local manager_mount
  local expected_mount
  local mode
  local sqlite_file
  local python_bin="${PYTHON_BIN:-python3}"
  local free_kb

  DOCTOR_ERRORS=0
  DOCTOR_WARNINGS=0
  collect_runtime_status
  install_dir="$RUNTIME_INSTALL_DIR"
  print_section "配置体检（只读）"
  printf '安装目录：%s\n' "$install_dir"
  printf '安装类型：%s\n' "$RUNTIME_INSTALL_TYPE"

  case "$RUNTIME_INSTALL_TYPE" in
    mixed) doctor_result error "同时存在新旧 Manager，可能重复消费用量队列" ;;
    not-installed|cpa-only) doctor_result warn "部署不完整: $RUNTIME_INSTALL_TYPE" ;;
    *) doctor_result ok "安装类型可识别: $RUNTIME_INSTALL_TYPE" ;;
  esac

  if [ -f "$install_dir/docker-compose.yml" ]; then
    if compose_in_dir "$install_dir" config >/dev/null 2>&1; then
      doctor_result ok "docker-compose.yml 解析通过"
    else
      doctor_result error "docker-compose.yml 无法通过 docker compose config"
    fi
  else
    doctor_result error "缺少 docker-compose.yml"
  fi

  if [ -f "$install_dir/config.yaml" ]; then
    if grep -Eq '^[[:space:]]*remote-management:' "$install_dir/config.yaml"; then
      doctor_result ok "存在远程管理配置"
    else
      doctor_result error "缺少 remote-management 配置"
    fi
    if grep -Eq '^[[:space:]]*allow-remote:[[:space:]]*true' "$install_dir/config.yaml"; then
      doctor_result ok "远程管理访问已启用"
    else
      doctor_result warn "未确认启用 remote-management.allow-remote"
    fi
    if grep -Eq '^[[:space:]]*usage-statistics-enabled:[[:space:]]*true' "$install_dir/config.yaml"; then
      doctor_result ok "用量统计已启用"
    else
      doctor_result warn "未确认启用 usage-statistics-enabled"
    fi
  else
    doctor_result error "缺少 config.yaml"
  fi

  cpa_port="$RUNTIME_CPA_HOST_PORT"
  manager_port="$RUNTIME_MANAGER_HOST_PORT"
  if validate_port "$cpa_port" && validate_port "$manager_port"; then
    if [ "$cpa_port" = "$manager_port" ]; then
      doctor_result error "CPA 与 Manager 使用相同宿主机端口: $cpa_port"
    else
      doctor_result ok "端口配置有效: CPA=$cpa_port, Manager=$manager_port"
    fi
  else
    doctor_result error "检测到无效端口: CPA=$cpa_port, Manager=$manager_port"
  fi

  if [ -f "$install_dir/.secrets.txt" ]; then
    mode="$(stat -c '%a' "$install_dir/.secrets.txt" 2>/dev/null || true)"
    if [ "$mode" = "600" ]; then
      doctor_result ok ".secrets.txt 权限为 600"
    else
      doctor_result warn ".secrets.txt 权限应为 600，当前为 ${mode:-未知}"
    fi
  else
    doctor_result error "缺少 .secrets.txt，部分明文管理密钥可能无法恢复"
  fi

  if [ -d "$install_dir/auths" ] && [ -w "$install_dir/auths" ]; then
    doctor_result ok "认证目录存在且可写"
  else
    doctor_result error "auths 认证目录不存在或不可写"
  fi

  if [ -f "$install_dir/cpa-manager-data/data.key" ]; then
    mode="$(stat -c '%a' "$install_dir/cpa-manager-data/data.key" 2>/dev/null || true)"
    case "$mode" in
      600|400) doctor_result ok "data.key 存在且权限受限" ;;
      *) doctor_result warn "data.key 权限过宽或未知: ${mode:-未知}" ;;
    esac
  else
    doctor_result error "缺少 cpa-manager-data/data.key，Plus 加密数据可能无法恢复"
  fi

  sqlite_file="$install_dir/cpa-manager-data/usage.sqlite"
  if [ -s "$sqlite_file" ]; then
    if "$python_bin" - "$sqlite_file" <<'PY' >/dev/null 2>&1
import sqlite3
import sys

db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True, timeout=10)
try:
    result = db.execute("PRAGMA quick_check").fetchone()
    if not result or result[0] != "ok":
        raise SystemExit(1)
finally:
    db.close()
PY
    then
      doctor_result ok "Manager SQLite quick_check 通过"
    else
      doctor_result error "Manager SQLite quick_check 失败或 Python 不可用"
    fi
  else
    doctor_result warn "未找到可检查的 usage.sqlite"
  fi

  if [ "$RUNTIME_PLUS_EXISTS" = "true" ] || [ "$RUNTIME_LEGACY_EXISTS" = "true" ]; then
    manager_mount="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' "$RUNTIME_MANAGER_CONTAINER" 2>/dev/null || true)"
    expected_mount="$(readlink -f "$install_dir/cpa-manager-data" 2>/dev/null || printf '%s' "$install_dir/cpa-manager-data")"
    manager_mount="$(readlink -f "$manager_mount" 2>/dev/null || printf '%s' "$manager_mount")"
    if [ "$manager_mount" = "$expected_mount" ]; then
      doctor_result ok "Manager /data 挂载指向受管数据目录"
    else
      doctor_result error "Manager /data 挂载异常: ${manager_mount:-未检测到}"
    fi
  fi

  if [ -d "$install_dir/snapshots" ]; then
    mode="$(stat -c '%a' "$install_dir/snapshots" 2>/dev/null || true)"
    if [ "$mode" = "700" ]; then
      doctor_result ok "快照根目录权限为 700"
    else
      doctor_result warn "快照根目录权限应为 700，当前为 ${mode:-未知}"
    fi
  else
    doctor_result warn "尚未创建快照目录"
  fi

  free_kb="$(df -Pk "$install_dir" 2>/dev/null | awk 'NR == 2 { print $4 }')"
  if [[ "$free_kb" =~ ^[0-9]+$ ]]; then
    if (( free_kb < 262144 )); then
      doctor_result error "磁盘剩余空间低于 256 MiB"
    elif (( free_kb < 1048576 )); then
      doctor_result warn "磁盘剩余空间低于 1 GiB"
    else
      doctor_result ok "磁盘剩余空间: $(human_file_size "$((free_kb * 1024))")"
    fi
  else
    doctor_result warn "无法读取磁盘剩余空间"
  fi

  print_section "体检结论"
  printf '错误：%s 项    警告：%s 项\n' "$DOCTOR_ERRORS" "$DOCTOR_WARNINGS"
  if [ "$DOCTOR_ERRORS" -gt 0 ]; then
    printf '%b  配置体检未通过，请先处理错误项。\n' "$ICON_ERROR"
    return 1
  fi
  printf '%b  配置体检通过；警告项建议人工确认。\n' "$ICON_OK"
}

logs_cpa_cpam() {
  local choice
  local manager_container
  manager_container="$(active_cpam_container)"
  cat <<'EOF'
请选择要查看的日志：
1) cli-proxy-api
2) 当前 Manager
3) 两个都看最近 120 行
EOF
  if [ -t 0 ]; then
    printf "请输入选项 [3]: "
    read -r choice || choice="3"
  else
    choice="3"
  fi
  if [ -z "$choice" ]; then
    choice="3"
  fi

  case "$choice" in
    1) docker logs -f --tail=120 "$CPA_CONTAINER" ;;
    2) docker logs -f --tail=120 "$manager_container" ;;
    3)
      printf '\n===== %s =====\n' "$CPA_CONTAINER"
      docker logs --tail=120 "$CPA_CONTAINER" || true
      printf '\n===== %s =====\n' "$manager_container"
      docker logs --tail=120 "$manager_container" || true
      ;;
    *) warn "无效选项" ;;
  esac
}

show_keys() {
  local install_dir
  local secrets_file
  local api_key
  local mgt_key

  install_dir="$(detect_install_dir)"
  secrets_file="$install_dir/.secrets.txt"

  if [ -f "$secrets_file" ]; then
    cat "$secrets_file"
    return 0
  fi

  warn "未找到 $secrets_file，尝试从 config.yaml 读取"
  if [ ! -f "$install_dir/config.yaml" ]; then
    die "未找到 config.yaml，无法查看密钥"
  fi

  api_key="$(awk '/api-keys:/ { in_api=1; next } in_api && /^[[:space:]]*-[[:space:]]*"/ { gsub(/^[[:space:]]*-[[:space:]]*"/, ""); gsub(/"[[:space:]]*$/, ""); print; exit }' "$install_dir/config.yaml")"
  mgt_key="$(awk '/secret-key:/ { line=$0; sub(/^[^:]*:[[:space:]]*/, "", line); gsub(/^"/, "", line); gsub(/"[[:space:]]*$/, "", line); print line; exit }' "$install_dir/config.yaml")"

  if [ -n "$api_key" ]; then
    printf 'API_KEY=%s\n' "$api_key"
  else
    warn "未能从 config.yaml 读取 API_KEY"
  fi

  if [[ "$mgt_key" == \$2a\$* || "$mgt_key" == \$2b\$* || "$mgt_key" == \$2y\$* ]]; then
    warn "config.yaml 里的 Management Key 是 bcrypt hash，无法反推出明文，请查看 .secrets.txt 或重新设置"
  elif [ -n "$mgt_key" ]; then
    printf 'MGT_KEY=%s\n' "$mgt_key"
  else
    warn "未能从 config.yaml 读取 MGT_KEY"
  fi
}

# 更新 CLIProxyAPI 配置中的 Management Key，不依赖原值是否已被转换为 bcrypt。
replace_cpa_management_key() {
  local config_file="$1"
  local new_key="$2"
  local escaped_key
  local temp_file="${config_file}.tmp.$$"

  escaped_key="$(yaml_escape_double "$new_key")"
  awk -v value="$escaped_key" '
    /^remote-management:[[:space:]]*$/ { in_section=1 }
    in_section && /^[^[:space:]]/ && !/^remote-management:/ { in_section=0 }
    in_section && /^[[:space:]]+secret-key:/ {
      print "  secret-key: \"" value "\""
      updated=1
      next
    }
    { print }
    END { if (!updated) exit 42 }
  ' "$config_file" > "$temp_file" || {
    rm -f "$temp_file"
    return 1
  }
  mv -f "$temp_file" "$config_file"
}

# 同步 Compose 中的 Plus 管理员密钥，避免数据库重建时又使用旧环境变量。
replace_compose_admin_key() {
  local compose_file="$1"
  local new_key="$2"
  local escaped_key
  local temp_file="${compose_file}.tmp.$$"

  escaped_key="$(yaml_escape_double "$new_key")"
  awk -v value="$escaped_key" '
    /^[[:space:]]+CPA_MANAGER_ADMIN_KEY:/ {
      sub(/CPA_MANAGER_ADMIN_KEY:.*/, "CPA_MANAGER_ADMIN_KEY: \"" value "\"")
      updated=1
    }
    { print }
    END { if (!updated) exit 42 }
  ' "$compose_file" > "$temp_file" || {
    rm -f "$temp_file"
    return 1
  }
  mv -f "$temp_file" "$compose_file"
}

wait_for_bearer_endpoint() {
  local url="$1"
  local key="$2"
  local attempt

  for attempt in 1 2 3 4 5 6; do
    if curl -fsS --max-time 8 -H "Authorization: Bearer $key" "$url" >/dev/null 2>&1; then
      return 0
    fi
    [ "$attempt" -lt 6 ] && sleep 3
  done
  return 1
}

# 按 CPA Manager Plus 官方 reset-admin-key 命令重置登录密钥。
reset_plus_admin_key() {
  local install_dir="$1"
  local cpam_host_port="$2"
  local new_key="$3"
  local key_file="$install_dir/.new-cpamp-admin-key.$$"

  printf '%s\n' "$new_key" > "$key_file"
  chmod 600 "$key_file"
  log "停止 CPA Manager Plus 并调用官方密钥重置命令"
  compose_in_dir "$install_dir" stop cpa-manager-plus >/dev/null || {
    rm -f "$key_file"
    return 1
  }
  if ! compose_in_dir "$install_dir" run --rm --no-deps \
    -v "$key_file:/run/secrets/new_admin_key:ro" \
    cpa-manager-plus reset-admin-key --admin-key-file /run/secrets/new_admin_key >/dev/null; then
    rm -f "$key_file"
    compose_in_dir "$install_dir" up -d --no-deps cpa-manager-plus >/dev/null 2>&1 || true
    return 1
  fi
  rm -f "$key_file"

  replace_compose_admin_key "$install_dir/docker-compose.yml" "$new_key" || return 1
  compose_in_dir "$install_dir" up -d --no-deps cpa-manager-plus >/dev/null || return 1
  wait_for_bearer_endpoint "http://127.0.0.1:${cpam_host_port}/status" "$new_key"
}

# 重置 CPA Management Key，并通过 Plus 配置接口同步其 CPA 连接凭证。
reset_cpa_management_key() {
  local install_dir="$1"
  local cpa_host_port="$2"
  local cpam_host_port="$3"
  local plus_admin_key="$4"
  local new_key="$5"
  local current_config="$install_dir/.cpamp-config-before-key-reset.$$"
  local update_payload="$install_dir/.cpamp-config-key-reset.$$"
  local plus_config_url="http://127.0.0.1:${cpam_host_port}/usage-service/config"

  if ! curl -fsS --max-time 10 \
    -H "Authorization: Bearer $plus_admin_key" \
    "$plus_config_url" > "$current_config"; then
    rm -f "$current_config" "$update_payload"
    warn "无法读取 Plus 当前连接配置；如 Plus 登录密钥也已丢失，请选择两个全部重置"
    return 1
  fi
  if ! jq -e '.config.cpaConnection' "$current_config" >/dev/null 2>&1; then
    rm -f "$current_config" "$update_payload"
    warn "Plus 当前连接配置格式异常"
    return 1
  fi
  jq --arg key "$new_key" \
    '{config: (.config | .cpaConnection.managementKey = $key)}' \
    "$current_config" > "$update_payload"

  replace_cpa_management_key "$install_dir/config.yaml" "$new_key" || {
    rm -f "$current_config" "$update_payload"
    warn "config.yaml 中未找到 remote-management.secret-key"
    return 1
  }
  log "重启 CLIProxyAPI 以应用新的 Management Key"
  compose_in_dir "$install_dir" restart cli-proxy-api >/dev/null || {
    rm -f "$current_config" "$update_payload"
    return 1
  }
  if ! wait_for_bearer_endpoint "http://127.0.0.1:${cpa_host_port}/v0/management/config" "$new_key"; then
    rm -f "$current_config" "$update_payload"
    warn "CLIProxyAPI 新 Management Key 验证失败"
    return 1
  fi
  if ! curl -fsS --max-time 15 -X PUT \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $plus_admin_key" \
    --data-binary "@$update_payload" \
    "$plus_config_url" >/dev/null; then
    rm -f "$current_config" "$update_payload"
    warn "Plus 同步新的 CPA Management Key 失败"
    return 1
  fi

  rm -f "$current_config" "$update_payload"
  return 0
}

rollback_management_key_reset() {
  local install_dir="$1"
  local backup_file="$2"
  local failed_dir
  failed_dir="$install_dir/cpa-manager-data.failed-key-reset-$(timestamp)"

  warn "密钥验证失败，正在恢复操作前快照"
  compose_in_dir "$install_dir" stop >/dev/null 2>&1 || true
  if [ -d "$install_dir/cpa-manager-data" ]; then
    mv "$install_dir/cpa-manager-data" "$failed_dir" || return 1
  fi
  rm -f "$install_dir/docker-compose.yml" "$install_dir/config.yaml" "$install_dir/.secrets.txt"
  tar -C "$install_dir" -xzf "$backup_file" || return 1
  chmod 600 "$install_dir/.secrets.txt" 2>/dev/null || true
  compose_in_dir "$install_dir" up -d --remove-orphans >/dev/null || return 1
  warn "已恢复旧密钥和数据；失败现场保留在 $failed_dir"
}

reset_management_keys() {
  local install_dir
  local install_type
  local choice
  local cpa_host_port
  local cpam_host_port
  local old_plus_key
  local new_plus_key=""
  local new_mgt_key=""
  local active_plus_key
  local backup_file
  local reset_failed="false"

  install_type="$(detect_install_type)"
  [ "$install_type" = "plus" ] || die "密钥重置仅支持已部署的 CPA Manager Plus"
  install_dir="$(detect_install_dir)"
  ensure_compose_dir "$install_dir"
  collect_runtime_status "$install_dir"
  cpa_host_port="$RUNTIME_CPA_HOST_PORT"
  cpam_host_port="$RUNTIME_MANAGER_HOST_PORT"
  old_plus_key="$(load_secrets_value "$install_dir/.secrets.txt" "CPAMP_ADMIN_KEY" || true)"

  print_section "重新生成管理密钥"
  cat <<'EOF'
1) 只重置 CPA Manager Plus 管理员密钥
2) 只重置 CPA Management Key
3) 两个全部重置
EOF
  choice="$(read_with_default "请选择重置范围 [1]: " "1")"
  case "$choice" in
    1) new_plus_key="$(generate_cpamp_admin_key)" ;;
    2) new_mgt_key="$(generate_mgt_key)" ;;
    3)
      new_plus_key="$(generate_cpamp_admin_key)"
      new_mgt_key="$(generate_mgt_key)"
      ;;
    *) die "无效重置范围: $choice" ;;
  esac

  if [ -n "$new_mgt_key" ] && [ -z "$new_plus_key" ] && [ -z "$old_plus_key" ]; then
    die "未找到当前 Plus 管理员密钥，无法同步 CPA 连接；请选择两个全部重置"
  fi

  printf '安装目录：%s\n' "$install_dir"
  printf '重置范围：%s\n' "$choice"
  printf '安全快照：操作前自动保存到 %s/system/\n' "$(snapshot_root_dir "$install_dir")"
  printf '影响：重置期间相关服务会短暂停止；新密钥只在全部验证成功后显示。\n'
  if ! ask_yes_no "确认重新生成并覆盖所选管理密钥" "Y"; then
    log "已取消密钥重置"
    return 0
  fi

  create_snapshot_record "$install_dir" system pre-key-reset "管理密钥重置前自动保护" consistent || die "密钥重置前快照失败"
  backup_file="$CREATED_SNAPSHOT_DIR/snapshot.tar.gz"

  active_plus_key="$old_plus_key"
  if [ -n "$new_plus_key" ]; then
    if reset_plus_admin_key "$install_dir" "$cpam_host_port" "$new_plus_key"; then
      active_plus_key="$new_plus_key"
    else
      reset_failed="true"
    fi
  fi
  if [ "$reset_failed" = "false" ] && [ -n "$new_mgt_key" ]; then
    if ! reset_cpa_management_key "$install_dir" "$cpa_host_port" "$cpam_host_port" "$active_plus_key" "$new_mgt_key"; then
      reset_failed="true"
    fi
  fi

  if [ "$reset_failed" = "true" ]; then
    rollback_management_key_reset "$install_dir" "$backup_file" || die "自动恢复失败，请使用快照手动恢复: $backup_file"
    die "密钥重置失败，已恢复旧配置"
  fi

  [ -n "$new_plus_key" ] && upsert_secrets_value "$install_dir/.secrets.txt" "CPAMP_ADMIN_KEY" "$new_plus_key"
  [ -n "$new_mgt_key" ] && upsert_secrets_value "$install_dir/.secrets.txt" "MGT_KEY" "$new_mgt_key"
  print_section "密钥重置成功"
  printf '%b  新密钥已经写入配置、通过接口验证并保存到 %s/.secrets.txt\n' "$ICON_OK" "$install_dir"
  [ -n "$new_plus_key" ] && printf 'CPAMP_ADMIN_KEY=%s\n' "$new_plus_key"
  [ -n "$new_mgt_key" ] && printf 'MGT_KEY=%s\n' "$new_mgt_key"
  printf '请立即保存以上密钥；旧密钥已经失效。\n'
}

safe_install_dir_for_delete() {
  local install_dir="$1"
  [ -n "$install_dir" ] || return 1
  [ "$install_dir" != "/" ] || return 1
  [ "$install_dir" != "/opt" ] || return 1
  [ "$install_dir" != "/root" ] || return 1
  return 0
}

uninstall_cpa_cpam() {
  local detected_dir
  local install_dir

  detected_dir="$(detect_install_dir)"
  install_dir="$(read_with_default "安装目录，回车使用检测值 [$detected_dir]: " "$detected_dir")"

  print_section "卸载确认"
  printf '安装目录：%s\n' "$install_dir"
  show_menu_status
  printf '\n第一步会停止并删除 Compose 容器和网络，不会立即删除数据目录。\n'
  if ! ask_yes_no "确认卸载 CPA + CPA Manager Plus" "N"; then
    log "已取消卸载"
    return 0
  fi

  remove_snapshot_schedule
  if [ -f "$install_dir/docker-compose.yml" ]; then
    compose_in_dir "$install_dir" down || warn "docker compose down 失败，请手动检查"
  else
    warn "未找到 docker-compose.yml，跳过 docker compose down"
  fi

  if ask_yes_no "是否保留数据" "Y"; then
    log "已保留安装目录: $install_dir"
    return 0
  fi

  safe_install_dir_for_delete "$install_dir" || die "拒绝删除危险目录: $install_dir"
  if ask_yes_no "确认删除安装目录 $install_dir" "N"; then
    rm -rf -- "$install_dir"
    log "已删除安装目录: $install_dir"
  else
    log "已保留安装目录: $install_dir"
  fi
}

codex_login_hint() {
  local install_dir
  install_dir="$(detect_install_dir)"

  cat <<EOF
cd $install_dir
docker compose exec cli-proxy-api /CLIProxyAPI/CLIProxyAPI -no-browser --codex-login

按提示在你本地电脑执行它给出的 ssh -L 隧道命令，然后用本地浏览器打开授权链接。
EOF
}

# 从最近 24 小时的两个容器和文件日志中提取访问记录，并按消费行为、管理行为严格分类。
# 仅将带有明确路径和结果的请求计入榜单，避免健康检查、静态资源和普通日志污染统计。
collect_recent_access_ips() {
  local install_dir="$1"
  local log_sample="$2"
  local python_bin="${PYTHON_BIN:-python3}"

  : > "$log_sample"
  if container_exists "$CPA_CONTAINER"; then
    docker logs --since 24h "$CPA_CONTAINER" >> "$log_sample" 2>&1 || true
  fi
  if container_exists "$CPAM_CONTAINER"; then
    docker logs --since 24h "$CPAM_CONTAINER" >> "$log_sample" 2>&1 || true
  fi

  if [ -d "$install_dir/logs" ]; then
    while IFS= read -r -d '' log_file; do
      tail -n 50000 "$log_file" >> "$log_sample" 2>/dev/null || true
    done < <(find "$install_dir/logs" -type f -mmin -1440 -print0 2>/dev/null)
  fi

  if ! "$python_bin" -c 'import ipaddress' >/dev/null 2>&1; then
    err "无法执行 Python IP 解析器: $python_bin"
    return 1
  fi

  "$python_bin" - "$log_sample" <<'PY'
import collections
import ipaddress
import re
import sys
from urllib.parse import urlsplit

path = sys.argv[1]
lines = open(path, "r", encoding="utf-8", errors="ignore")

# CLIProxyAPI Gin 日志与 CPA Manager Plus RequestLogger 的官方格式。
cli_access = re.compile(
    r'(?P<status>[1-5][0-9]{2})\s*\|[^|]*\|\s*(?P<remote>[^|]+?)\s*\|\s*'
    r'(?P<method>GET|POST|PUT|PATCH|DELETE|OPTIONS|HEAD)\s+"(?P<path>[^"]+)"',
    re.I,
)
plus_access = re.compile(
    r'\bhttp\s+(?P<method>GET|POST|PUT|PATCH|DELETE|OPTIONS|HEAD)\s+(?P<path>\S+)\s+'
    r'status=(?P<status>[1-5][0-9]{2})\b.*?\bremote=(?P<remote>\S+)',
    re.I,
)
# 只用于诊断“不带明确 HTTP 方法和路径”的日志；绝不据此推断行为类型。
ambiguous_status = re.compile(r'\b(?:status|status_code|code)\s*[=:]?\s*[1-5][0-9]{2}\b', re.I)
ambiguous_ip = re.compile(r'(?<![\w:])(?:\d{1,3}\.){3}\d{1,3}(?![\w:])|(?<![\w:])(?:[0-9a-f]{0,4}:){2,}[0-9a-f:]+(?![\w:])', re.I)

consumption_exact = {
    "/v1/chat/completions",
    "/v1/completions",
    "/v1/embeddings",
    "/v1/moderations",
    "/v1/messages",
    "/v1/responses",
    "/v1/responses/compact",
    "/v1beta/interactions",
}
consumption_prefixes = (
    "/v1/images/",
    "/v1/videos",
    "/v1/audio/",
    "/openai/v1/videos",
    "/backend-api/codex/responses",
    "/v1beta/models/",
)
management_exact = {
    "/v0/management",
    "/usage-service/config",
    "/usage-service/account-processing-policy",
    "/usage-service/quota-cooldowns",
    "/setup",
}
management_prefixes = ("/v0/management/",)
filtered_exact = {
    "/",
    "/health",
    "/healthz",
    "/status",
    "/usage-service/info",
    "/management.html",
    "/v1/models",
    "/v1/messages/count_tokens",
    "/v1beta/models",
    "/models",
}
filtered_prefixes = (
    "/assets/",
    "/static/",
    "/favicon",
    "/v0/resource/plugins/",
    "/anthropic/callback",
    "/codex/callback",
    "/antigravity/callback",
)

ip_counts = {
    behavior: {outcome: collections.Counter() for outcome in ("success", "failure")}
    for behavior in ("consumption", "management")
}
auth_failures = {
    "consumption": collections.Counter(),
    "management": collections.Counter(),
}
management_events = collections.Counter()
diagnostics = collections.Counter()
seen_lines = set()


def parse_remote(raw):
    value = raw.strip().strip('"')
    if value.startswith("[") and "]" in value:
        value = value[1:value.index("]")]
    else:
        try:
            return ipaddress.ip_address(value)
        except ValueError:
            if value.count(":") == 1:
                value = value.rsplit(":", 1)[0]
    try:
        return ipaddress.ip_address(value)
    except ValueError:
        return None


def classify_path(request_path):
    clean_path = urlsplit(request_path).path.rstrip("/") or "/"
    if clean_path in consumption_exact or clean_path.startswith(consumption_prefixes):
        return "consumption", clean_path
    if clean_path in management_exact or clean_path.startswith(management_prefixes):
        return "management", clean_path
    if clean_path in filtered_exact or clean_path.startswith(filtered_prefixes):
        return "filtered", clean_path
    return "unclassified", clean_path


for line in lines:
    # 同一条 CLIProxyAPI 日志可能同时出现在容器输出和文件日志中，只统计一次。
    if line in seen_lines:
        continue
    seen_lines.add(line)
    match = cli_access.search(line) or plus_access.search(line)
    if not match:
        if ambiguous_status.search(line) and ambiguous_ip.search(line):
            diagnostics["no_path"] += 1
        continue
    address = parse_remote(match.group("remote"))
    if address is None or address.is_multicast or address.is_unspecified:
        diagnostics["invalid_ip"] += 1
        continue

    status = int(match.group("status"))
    method = match.group("method").upper()
    behavior, request_path = classify_path(match.group("path"))
    if behavior in ("filtered", "unclassified"):
        diagnostics[behavior] += 1
        continue
    if 200 <= status < 300:
        outcome = "success"
    elif 400 <= status < 600:
        outcome = "failure"
    else:
        diagnostics["no_result"] += 1
        continue

    normalized_address = str(address)
    ip_counts[behavior][outcome][normalized_address] += 1
    if status in (401, 403):
        auth_failures[behavior][normalized_address] += 1
    if behavior == "management":
        management_events[(outcome, method, request_path)] += 1

for behavior in ("consumption", "management"):
    for outcome in ("success", "failure"):
        for address, count in ip_counts[behavior][outcome].most_common():
            scope = "public" if ipaddress.ip_address(address).is_global else "internal"
            print(f"ip\t{behavior}\t{outcome}\t{count}\t{address}\t{scope}")
    for address, count in auth_failures[behavior].most_common():
        scope = "public" if ipaddress.ip_address(address).is_global else "internal"
        print(f"auth\t{behavior}\t{count}\t{address}\t{scope}")

for (outcome, method, request_path), count in management_events.most_common(30):
    print(f"event\t{outcome}\t{count}\t{method}\t{request_path}")
for name in ("filtered", "unclassified", "invalid_ip", "no_result", "no_path"):
    print(f"diagnostic\t{name}\t{diagnostics[name]}")
PY
}

# 使用统一列宽输出 IP 排名；每张榜单最多展示 30 个来源，避免终端被长日志淹没。
print_access_ip_ranking() {
  local title="$1"
  local report_file="$2"
  local empty_message="$3"
  local geo_report="$4"

  print_section "$title"
  if [ -s "$report_file" ]; then
    printf '%-8s %-39s %s\n' '次数' 'IP 地址' '归属信息'
    printf '%s\n' '────────────────────────────────────────────────────────────────────────────────────────'
    head -n 30 "$report_file" | awk -F '\t' -v geo_file="$geo_report" '
      BEGIN {
        while ((getline line < geo_file) > 0) {
          split(line, fields, "\t")
          geo[fields[1]] = fields[2]
        }
        close(geo_file)
      }
      {
        if ($3 == "internal") {
          location = "内网/本地地址"
        } else if ($2 in geo) {
          location = geo[$2]
        } else {
          location = "公网 IP（未查询归属）"
        }
        printf "%-8s %-39s %s\n", $1, $2, location
      }'
  else
    printf '%b  %s\n' "$ICON_OK" "$empty_message"
  fi
}

# 消费与管理审计只复用公网 IP 清单生成和 Batch 查询代码，输入报告始终相互隔离。
collect_ranked_public_ips() {
  local success_report="$1"
  local failure_report="$2"
  local public_ips="$3"

  {
    head -n 30 "$success_report"
    head -n 30 "$failure_report"
  } | awk -F '\t' '$3 == "public" { print $2 }' | sort -u | head -n 100 > "$public_ips"
}

# 统一生成 IP-API Batch 请求体，调用方只负责提供已去重的公网 IP 清单。
build_ip_api_batch_request() {
  local public_ips="$1"
  local request_file="$2"

  jq -R -s '
    split("\n")
    | map(select(length > 0) | {
        query: .,
        fields: "status,message,country,countryCode,regionName,city,isp,org,as,asname,proxy,hosting,query"
      })' "$public_ips" > "$request_file"
}

# 调用公共 IP-API Batch 接口并把结果写成统一的 IP/归属 TSV。
# 该函数不关心 IP 来自消费审计、管理审计还是其他只读报告，避免重复实现网络请求和解析逻辑。
query_public_ip_geolocation_batch() {
  local public_ips="$1"
  local geo_report="$2"
  local work_dir="$3"
  local request_file="$work_dir/ip-api-request.json"
  local response_file="$work_dir/ip-api-response.json"
  local request_url
  local transport_label

  : > "$geo_report"
  if [ ! -s "$public_ips" ]; then
    log "没有需要查询归属的公网 IP"
    return 0
  fi

  printf '待查询公网 IP：%s 个；内网和本地地址不会发送。\n' "$(wc -l < "$public_ips" | tr -d ' ')"
  case "$IP_API_BATCH_URL" in
    https://*) transport_label="HTTPS" ;;
    http://*) transport_label="HTTP" ;;
    *) transport_label="当前配置协议" ;;
  esac
  printf '隐私提示：Batch 接口使用 %s，请求中的公网 IP 会发送给配置的归属查询服务。\n' "$transport_label"
  if ! ask_yes_no "确认调用 $IP_API_BATCH_URL 批量查询排行榜公网 IP" "N"; then
    log "已跳过公网 IP 归属查询，排行榜仍会正常显示"
    return 0
  fi

  build_ip_api_batch_request "$public_ips" "$request_file" || {
    warn "无法生成 IP-API Batch 请求，继续显示本地排行榜"
    return 1
  }

  if [[ "$IP_API_BATCH_URL" == *\?* ]]; then
    request_url="${IP_API_BATCH_URL}&lang=zh-CN"
  else
    request_url="${IP_API_BATCH_URL}?lang=zh-CN"
  fi

  if ! curl -fsS --max-time 25 \
    -H 'Content-Type: application/json' \
    -X POST \
    --data-binary "@$request_file" \
    "$request_url" > "$response_file"; then
    warn "IP-API Batch 请求失败，继续显示不含归属信息的排行榜"
    return 1
  fi
  if ! jq -e 'type == "array"' "$response_file" >/dev/null 2>&1; then
    warn "IP-API Batch 返回格式异常，继续显示不含归属信息的排行榜"
    return 1
  fi

  jq -r '
    .[]
    | if .status == "success" then
        [
          .query,
          (([.country, .regionName, .city] | map(select(. != null and . != "")) | join(" / "))
           + (if (.as // "") != "" then " | " + .as else "" end)
           + (if (.isp // "") != "" then " | " + .isp else "" end)
           + (if .proxy == true then " | 代理" else "" end)
           + (if .hosting == true then " | 机房" else "" end))
        ]
      else
        [.query, ("查询失败：" + (.message // "未知错误"))]
      end
    | @tsv' "$response_file" > "$geo_report"

  log "IP-API Batch 归属查询完成"
}

# 仅把当前审计两张榜单前 30 名中的公网 IP 发给 IP-API；内网和回环地址只在本地标记。
# 消费和管理审计分别传入自己的报告文件，公共查询层不会混合两类数据。
query_ranked_ip_geolocation() {
  local success_report="$1"
  local failure_report="$2"
  local geo_report="$3"
  local work_dir="$4"
  local public_ips="$work_dir/public-ips.txt"

  : > "$geo_report"
  collect_ranked_public_ips "$success_report" "$failure_report" "$public_ips"
  print_section "公网 IP 归属查询（IP-API Batch）"
  query_public_ip_geolocation_batch "$public_ips" "$geo_report" "$work_dir"
}

# 管理行为除 IP 排名外，再显示方法和脱敏路径，帮助判断发生了查看、修改还是删除操作。
print_management_event_summary() {
  local event_report="$1"

  print_section "管理操作明细（前 30）"
  if [ ! -s "$event_report" ]; then
    printf '%b  最近 24 小时未识别到管理操作\n' "$ICON_OK"
    return 0
  fi
  printf '%-8s %-8s %-8s %s\n' '结果' '次数' '方法' '管理路径'
  printf '%s\n' '────────────────────────────────────────────────────────────────────────────────────────'
  head -n 30 "$event_report" | awk -F '\t' '
    {
      result = ($1 == "success") ? "成功" : "失败"
      printf "%-8s %-8s %-8s %s\n", result, $2, $3, $4
    }'
}

behavior_audit() {
  local behavior="$1"
  local install_dir
  local temp_dir
  local log_sample
  local ip_report
  local success_report
  local failure_report
  local event_report
  local behavior_label
  local auth_failures
  local total_sources
  local success_calls
  local failure_calls
  local sample_lines
  local filtered_requests
  local unclassified_requests
  local no_path_requests
  local title_prefix

  case "$behavior" in
    consumption)
      behavior_label="消费行为"
      title_prefix="消费"
      ;;
    management)
      behavior_label="管理行为"
      title_prefix="管理操作"
      ;;
    *) die "未知审计类型: $behavior" ;;
  esac

  install_dir="$(detect_install_dir)"
  temp_dir="$(mktemp -d)"
  log_sample="$temp_dir/log-sample.txt"
  ip_report="$temp_dir/ip-report.tsv"
  success_report="$temp_dir/success-report.tsv"
  failure_report="$temp_dir/failure-report.tsv"
  event_report="$temp_dir/management-events.tsv"

  print_section "24 小时${behavior_label}审计"
  printf '说明：只统计已识别的%s接口；结果来自现有日志，是辅助审计线索。\n' "$behavior_label"
  printf '时间范围：最近 24 小时\n'
  printf '安装目录：%s\n' "$install_dir"

  if ! collect_recent_access_ips "$install_dir" "$log_sample" > "$ip_report"; then
    rm -rf "$temp_dir"
    die "无法解析最近 24 小时访问 IP"
  fi
  awk -F '\t' -v behavior="$behavior" '$1 == "ip" && $2 == behavior && $3 == "success" { print $4 "\t" $5 "\t" $6 }' "$ip_report" > "$success_report"
  awk -F '\t' -v behavior="$behavior" '$1 == "ip" && $2 == behavior && $3 == "failure" { print $4 "\t" $5 "\t" $6 }' "$ip_report" > "$failure_report"
  awk -F '\t' '$1 == "event" { print $2 "\t" $3 "\t" $4 "\t" $5 }' "$ip_report" > "$event_report"
  auth_failures="$(awk -F '\t' -v behavior="$behavior" '$1 == "auth" && $2 == behavior { total += $3 } END { print total + 0 }' "$ip_report")"
  total_sources="$({ cut -f 2 "$success_report"; cut -f 2 "$failure_report"; } | sort -u | grep -c . || true)"
  success_calls="$(awk -F '\t' '{ total += $1 } END { print total + 0 }' "$success_report")"
  failure_calls="$(awk -F '\t' '{ total += $1 } END { print total + 0 }' "$failure_report")"
  sample_lines="$(wc -l < "$log_sample" | tr -d ' ')"
  filtered_requests="$(awk -F '\t' '$1 == "diagnostic" && $2 == "filtered" { print $3 + 0 }' "$ip_report")"
  unclassified_requests="$(awk -F '\t' '$1 == "diagnostic" && $2 == "unclassified" { print $3 + 0 }' "$ip_report")"
  no_path_requests="$(awk -F '\t' '$1 == "diagnostic" && $2 == "no_path" { print $3 + 0 }' "$ip_report")"
  filtered_requests="${filtered_requests:-0}"
  unclassified_requests="${unclassified_requests:-0}"
  no_path_requests="${no_path_requests:-0}"

  printf '\n日志采样：%s 行\n' "$sample_lines"
  printf '已过滤健康检查、模型列表和静态资源：%s 条\n' "$filtered_requests"
  printf '未分类请求：%s 条（不进入任何榜单）\n' "$unclassified_requests"
  printf '无路径模糊日志：%s 条（仅诊断，不进入任何榜单）\n' "$no_path_requests"
  printf '\n已识别%s来源 IP：%s 个\n' "$behavior_label" "$total_sources"
  printf '成功：%s 次    失败：%s 次\n' "$success_calls" "$failure_calls"
  if [ "$auth_failures" -gt 0 ]; then
    printf '401 / 403 鉴权失败：%b  %s 条，请结合日志复核\n' "$ICON_WARN" "$auth_failures"
  else
    printf '401 / 403 鉴权失败：%b  未发现\n' "$ICON_OK"
  fi
  query_ranked_ip_geolocation "$success_report" "$failure_report" "$temp_dir/geo-report.tsv" "$temp_dir" || true
  print_access_ip_ranking "${title_prefix}成功 IP 排名（前 30）" "$success_report" "最近 24 小时未识别到${title_prefix}成功记录" "$temp_dir/geo-report.tsv"
  print_access_ip_ranking "${title_prefix}失败 IP 排名（前 30）" "$failure_report" "最近 24 小时未识别到${title_prefix}失败记录" "$temp_dir/geo-report.tsv"
  if [ "$behavior" = "management" ]; then
    print_management_event_summary "$event_report"
  fi
  printf '\n说明：2xx 计为成功，4xx/5xx 计为失败；消费和管理路径使用相互独立的白名单。\n'
  if [ "$sample_lines" -gt 0 ] && [ "$success_calls" -eq 0 ] && [ "$failure_calls" -eq 0 ]; then
    warn "日志存在但没有识别到${behavior_label}，请结合未分类数量并查看原始访问记录："
    printf 'docker logs --since 24h %s | tail -n 50\n' "$CPA_CONTAINER"
    printf 'docker logs --since 24h %s | tail -n 50\n' "$CPAM_CONTAINER"
    printf 'tail -n 50 %s/logs/main.log\n' "$install_dir"
  fi

  rm -rf "$temp_dir"
}

consumption_audit() {
  behavior_audit consumption
}

management_audit() {
  behavior_audit management
}

# -----------------------------------------------------------------------------
# 旧 CPA-Manager 到 Plus 的迁移与回滚
# -----------------------------------------------------------------------------

preflight_cpa_cpam() {
  local data_source

  print_section "迁移条件检查"
  if ! command -v docker >/dev/null 2>&1; then
    printf 'Docker: 未安装\n安装类型: not-installed\n'
    return 1
  fi
  if ! docker info >/dev/null 2>&1; then
    printf 'Docker: daemon 未运行\n安装类型: unknown\n'
    return 1
  fi

  collect_runtime_status
  printf '安装类型：%b%s%b\n' "$COLOR_BOLD" "$RUNTIME_INSTALL_TYPE" "$COLOR_RESET"
  printf '安装目录：%s\n' "$RUNTIME_INSTALL_DIR"
  print_section "服务状态"
  render_collected_runtime_status

  if [ "$RUNTIME_PLUS_EXISTS" = "true" ] || [ "$RUNTIME_LEGACY_EXISTS" = "true" ]; then
    data_source="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' "$RUNTIME_MANAGER_CONTAINER" 2>/dev/null || true)"
    print_section "迁移数据"
    printf 'Manager 容器：%s\n' "$RUNTIME_MANAGER_CONTAINER"
    printf 'Manager 镜像：%s\n' "${RUNTIME_PLUS_IMAGE:-${RUNTIME_LEGACY_IMAGE:-未知}}"
    printf '/data 来源：%s\n' "${data_source:-未检测到}"
  fi

  if [ -f "$RUNTIME_INSTALL_DIR/config.yaml" ]; then
    if grep -Eq '^[[:space:]]*usage-statistics-enabled:[[:space:]]*true' "$RUNTIME_INSTALL_DIR/config.yaml"; then
      printf '%b  用量统计已启用\n' "$ICON_OK"
    else
      warn "config.yaml 未确认启用 usage-statistics-enabled"
    fi
    if grep -Eq '^[[:space:]]*allow-remote:[[:space:]]*true' "$RUNTIME_INSTALL_DIR/config.yaml"; then
      printf '%b  远程管理已启用\n' "$ICON_OK"
    else
      warn "config.yaml 未确认启用 remote-management.allow-remote"
    fi
  else
    warn "未找到 $RUNTIME_INSTALL_DIR/config.yaml"
  fi

  case "$RUNTIME_INSTALL_TYPE" in
    legacy)
      print_section "预检结论"
      printf '%b  可进入迁移准备。正式迁移会停止旧 Manager 并创建一致性快照。\n' "$ICON_OK"
      ;;
    plus)
      print_section "预检结论"
      printf '%b  当前已经是 CPA Manager Plus，无需迁移。\n' "$ICON_OK"
      ;;
    mixed)
      warn "结论: 同时存在新旧 Manager，已阻断迁移，请先确认唯一消费者"
      return 1
      ;;
    *)
      warn "结论: 未发现可自动迁移的旧 CPA-Manager"
      return 1
      ;;
  esac
}

migration_assess() {
  print_section "迁移评估（只读）"
  preflight_cpa_cpam || return 1

  if [ "$RUNTIME_INSTALL_TYPE" != "legacy" ]; then
    return 0
  fi

  cat <<'EOF'

迁移计划（未执行任何写操作）:
1. 记录旧容器、镜像、端口、挂载和 Compose 状态
2. 仅停止旧 cpa-manager，保持 cli-proxy-api 运行
3. 创建包含完整 cpa-manager-data、Compose 和密钥文件的快照并校验
4. 保持 18317 外部端口和原 /data 挂载不变
5. 切换为 seakee/cpa-manager-plus 并生成独立 CPAMP_ADMIN_KEY
6. 验证 /health、/usage-service/info、鉴权 /status 和 data.key
7. 验证失败时从迁移前快照恢复旧 Manager

EOF
}

rollback_from_snapshot() {
  local install_dir="$1"
  local snapshot_dir="$2"
  local backup_file
  local metadata_file="$snapshot_dir/metadata.env"
  local expected_checksum
  local failed_dir
  failed_dir="$install_dir/cpa-manager-data.failed-$(timestamp)"

  [ -d "$snapshot_dir" ] || die "迁移快照不存在: $snapshot_dir"
  if [ -f "$metadata_file" ]; then
    validate_snapshot_metadata "$metadata_file" || die "迁移快照元数据或主归档校验失败: $metadata_file"
    backup_file="$snapshot_dir/$(snapshot_metadata_value "$metadata_file" archive)"
    expected_checksum="$(snapshot_metadata_value "$metadata_file" checksum_sha256)"
    verify_restorable_snapshot "$backup_file" "$expected_checksum" || die "迁移快照校验失败或包含不安全路径: $backup_file"
  else
    backup_file="$snapshot_dir/pre-migration.tar.gz"
    verify_snapshot_archive "$backup_file" || die "旧格式迁移快照损坏或不可读: $backup_file"
  fi

  if container_exists "$CPAM_CONTAINER"; then
    docker rm -f "$CPAM_CONTAINER" >/dev/null || warn "删除 Plus 容器失败，请手动检查"
  fi
  if [ -d "$install_dir/cpa-manager-data" ]; then
    mv "$install_dir/cpa-manager-data" "$failed_dir" || die "无法保留 Plus 失败现场"
    warn "Plus 数据现场已保留到: $failed_dir"
  fi

  rm -f "$install_dir/docker-compose.yml" "$install_dir/.secrets.txt"
  (cd "$install_dir" && tar -xzf "$backup_file") || die "恢复迁移前文件失败"
  chmod 600 "$install_dir/.secrets.txt" 2>/dev/null || true
  compose_in_dir "$install_dir" up -d --remove-orphans || die "旧 CPA-Manager 恢复后启动失败"
  log "已恢复迁移前 CPA-Manager 状态"
}

rollback_cpa_cpam() {
  local install_dir
  local marker_file
  local snapshot_dir

  install_dir="$(detect_install_dir)"
  marker_file="$install_dir/.last-migration-snapshot"
  if [ ! -f "$marker_file" ] && [ -f "$install_dir/.last-migration-backup" ]; then
    warn "发现旧版迁移标记文件，将只读兼容读取；后续迁移会使用 .last-migration-snapshot"
    marker_file="$install_dir/.last-migration-backup"
  fi
  [ -f "$marker_file" ] || die "未找到可用迁移快照标记: $marker_file"
  snapshot_dir="$(head -n 1 "$marker_file")"

  if ! ask_yes_no "确认使用 $snapshot_dir 回滚到旧 CPA-Manager" "N"; then
    log "已取消回滚"
    return 0
  fi
  rollback_from_snapshot "$install_dir" "$snapshot_dir"
}

migrate_cpa_cpam() {
  local install_dir
  local install_type
  local cpa_host_port
  local cpam_host_port
  local cpamp_admin_key
  local snapshot_dir
  local backup_file
  local temp_compose
  local current_cpa_image

  migration_assess || die "迁移评估未通过"
  install_type="$RUNTIME_INSTALL_TYPE"
  [ "$install_type" = "legacy" ] || die "当前安装类型不是 legacy，无需或无法迁移"
  install_dir="$RUNTIME_INSTALL_DIR"
  ensure_compose_dir "$install_dir"
  standard_manager_data_source "$install_dir" >/dev/null || die "当前 /data 不是标准 $install_dir/cpa-manager-data bind mount；为避免数据损坏，自动迁移已阻断"
  cpa_host_port="$RUNTIME_CPA_HOST_PORT"
  cpam_host_port="$RUNTIME_MANAGER_HOST_PORT"
  current_cpa_image="$RUNTIME_CPA_IMAGE"
  [ -n "$current_cpa_image" ] && CPA_IMAGE="$current_cpa_image"
  cpamp_admin_key="${CPAMP_ADMIN_KEY:-$(generate_cpamp_admin_key)}"

  if ! ask_yes_no "确认迁移到 CPA Manager Plus（CPA API 保持运行，Manager 会短暂停机）" "N"; then
    log "已取消迁移"
    return 0
  fi

  snapshot_dir="$install_dir/snapshots/migration/migration-$(timestamp)"
  backup_file="$snapshot_dir/pre-migration.tar.gz"
  temp_compose="$install_dir/docker-compose.yml.cpamp.tmp"
  mkdir -p "$snapshot_dir"
  chmod 700 "$install_dir/snapshots" "$install_dir/snapshots/migration" "$snapshot_dir"

  write_compose_yaml "$install_dir" "$cpa_host_port" "$cpam_host_port" "$cpamp_admin_key" "$temp_compose"
  compose_in_dir "$install_dir" -f "$temp_compose" config >/dev/null || die "Plus Compose 校验失败，未停止旧 Manager"

  log "停止旧 CPA-Manager 以创建一致性 SQLite 快照"
  docker stop "$LEGACY_CPAM_CONTAINER" >/dev/null || die "停止旧 CPA-Manager 失败"
  if ! create_snapshot_archive "$install_dir" "$backup_file" docker-compose.yml .secrets.txt cpa-manager-data; then
    docker start "$LEGACY_CPAM_CONTAINER" >/dev/null || true
    die "迁移前快照失败，旧 Manager 已尝试恢复"
  fi
  if ! verify_snapshot_archive "$backup_file"; then
    docker start "$LEGACY_CPAM_CONTAINER" >/dev/null || true
    die "迁移快照校验失败，旧 Manager 已尝试恢复"
  fi
  write_snapshot_metadata "$snapshot_dir" "$(basename "$snapshot_dir")" migration consistent \
    "旧 Manager 迁移前保护点" pre-migration.tar.gz "$install_dir" \
    "compose,secrets,manager-data,legacy-inspect" "legacy-migration" || {
    docker start "$LEGACY_CPAM_CONTAINER" >/dev/null || true
    die "迁移快照元数据生成失败，旧 Manager 已尝试恢复"
  }

  docker inspect "$LEGACY_CPAM_CONTAINER" > "$snapshot_dir/legacy-container-inspect.json" 2>/dev/null || true
  printf '%s\n' "$snapshot_dir" > "$install_dir/.last-migration-snapshot"
  mv -f "$temp_compose" "$install_dir/docker-compose.yml"
  upsert_secrets_value "$install_dir/.secrets.txt" "CPAMP_ADMIN_KEY" "$cpamp_admin_key"

  log "检查并启动 CPA Manager Plus"
  if ! pull_image_quietly "$CPAM_IMAGE" || ! compose_in_dir "$install_dir" up -d --no-deps cpa-manager-plus; then
    warn "Plus 启动失败，开始自动回滚"
    rollback_from_snapshot "$install_dir" "$snapshot_dir"
    return 1
  fi

  if ! validate_plus_migration "$install_dir" "$cpam_host_port" "$cpamp_admin_key"; then
    docker logs --tail=200 "$CPAM_CONTAINER" > "$snapshot_dir/plus-failed.log" 2>&1 || true
    warn "Plus 验证失败，开始自动回滚"
    rollback_from_snapshot "$install_dir" "$snapshot_dir"
    return 1
  fi

  docker rm "$LEGACY_CPAM_CONTAINER" >/dev/null || warn "旧 Manager 容器删除失败，请确认其保持停止"
  if ! create_consistent_snapshot_archive "$install_dir" "$snapshot_dir/post-migration.tar.gz" manager docker-compose.yml .secrets.txt cpa-manager-data; then
    warn "迁移已成功，但迁移后快照失败；Plus 已尝试恢复运行，请稍后执行 snapshot"
  else
    append_secondary_snapshot_archive "$snapshot_dir/metadata.env" "$snapshot_dir/post-migration.tar.gz" post_migration || warn "迁移后快照校验元数据写入失败"
  fi
  log "迁移成功。访问地址和端口保持不变: http://服务器IP:${cpam_host_port}/management.html"
  log "如需回滚，请运行: bash cpa-cpam-manager.sh rollback"
}

# -----------------------------------------------------------------------------
# 帮助、一级菜单与命令入口
# -----------------------------------------------------------------------------

print_help() {
  cat <<'EOF'
用法：
  bash cpa-cpam-manager.sh [命令]

命令：
  menu       交互菜单
  install    安装 / 重装 CPA + CPA Manager Plus
  upgrade    升级 CPA + CPA Manager Plus
  migration-assess  合并检查迁移条件并显示迁移计划（只读）
  migrate    正式迁移旧 Manager（可加 --dry-run）
  rollback   回滚最近一次迁移
  audit-consumption  消费行为审计：分别查看成功和失败 IP 排名
  audit-management   管理行为审计：分别查看成功和失败 IP 排名及操作明细
  reset-keys 重新生成 Plus 管理员密钥、CPA Management Key 或两者
  start      启动
  stop       停止
  restart    重启
  status     状态 / 健康检查
  doctor     配置体检（只读）
  logs       查看日志
  snapshot   创建快照
  snapshots  查看现有快照
  restore-snapshot  恢复快照
  snapshot-delete   删除指定人工或定时快照
  task-center  配置定时版本检查和自动快照
  snapshot-schedule 旧命令兼容别名，转发到 task-center
  scheduled-version-check  执行一次只读版本检查并保存报告
  keys       查看密钥 / 地址
  uninstall  卸载
  help       显示帮助

可用环境变量：
  INSTALL_DIR=/opt/cliproxy-cpam
  CPA_HOST_PORT=8317
  CPAM_HOST_PORT=18317
  CPA_IMAGE=eceasy/cli-proxy-api:latest
  API_KEY=sk-cpa-xxx
  MGT_KEY=mgt-cpa-xxx
  CPAMP_ADMIN_KEY=cpamp_xxx
  CPAM_IMAGE=seakee/cpa-manager-plus:latest
  CONFIRM_DEFAULT=Y
  ASSUME_YES=0
EOF
}

print_main_menu() {
  cat <<'EOF'

CPA Manager Plus 运维控制台
────────────────────────────────────────────────────────
部署管理
  1) 安装 / 重装             2) 升级
  3) 启动                     4) 停止
  5) 重启                     6) 状态 / 健康检查
  7) 配置体检（只读）

运行维护
  8) 查看日志                 9) 查看密钥 / 地址
 10) 重新生成管理密钥        11) Codex OAuth 登录

快照与恢复
 12) 创建快照                13) 查看现有快照
 14) 恢复快照                15) 删除指定快照
 16) 计划任务中心（版本检查 / 自动快照）

数据与迁移
 17) 迁移评估（只读）        18) 正式迁移到 Plus
 19) 回滚最近迁移

审计与安全
 20) 消费行为审计            21) 管理行为审计

其他
 22) 卸载

  0) 退出
────────────────────────────────────────────────────────
EOF
}

menu_loop() {
  local choice
  while true; do
    clear_screen
    show_menu_status
    print_main_menu
    printf "请选择操作 [0-22]: "
    read -r choice || choice="0"
    case "$choice" in
      1) install_cpa_cpam ;;
      2) upgrade_cpa_cpam ;;
      3) start_cpa_cpam ;;
      4) stop_cpa_cpam ;;
      5) restart_cpa_cpam ;;
      6) status_cpa_cpam ;;
      7) configuration_doctor || true ;;
      8) logs_cpa_cpam ;;
      9) show_keys ;;
      10) reset_management_keys ;;
      11) codex_login_hint ;;
      12) create_snapshot ;;
      13) list_snapshots ;;
      14) restore_snapshot ;;
      15) delete_snapshot ;;
      16) configure_task_center ;;
      17) migration_assess ;;
      18) migrate_cpa_cpam ;;
      19) rollback_cpa_cpam ;;
      20) consumption_audit ;;
      21) management_audit ;;
      22) uninstall_cpa_cpam ;;
      0) log "已退出"; break ;;
      *) warn "无效选项" ;;
    esac
    if [ "$choice" != "0" ]; then
      pause_before_menu
    fi
  done
}

main() {
  local command_name="${1:-menu}"
  local command_option="${2:-}"

  need_root

  case "$command_name" in
    help|-h|--help)
      print_help
      return 0
      ;;
    migrate)
      install_basic_deps
      ensure_docker_interactive
      if [ "$command_option" = "--dry-run" ]; then
        warn "migrate --dry-run 已合并为 migration-assess；正在执行统一迁移评估"
        migration_assess
      elif [ -z "$command_option" ]; then
        migrate_cpa_cpam
      else
        die "未知 migrate 参数: $command_option"
      fi
      return $?
      ;;
    rollback)
      install_basic_deps
      ensure_docker_interactive
      rollback_cpa_cpam
      return $?
      ;;
    menu|install|upgrade|start|stop|restart|status|doctor|logs|snapshot|snapshots|restore-snapshot|snapshot-delete|task-center|snapshot-schedule|scheduled-snapshot|scheduled-version-check|keys|reset-keys|uninstall|codex-login|audit-consumption|audit-management|migration-assess)
      install_basic_deps
      ensure_docker_interactive
      ;;
    *)
      print_help
      die "未知命令: $command_name"
      ;;
  esac

  case "$command_name" in
    menu) menu_loop ;;
    install) install_cpa_cpam ;;
    upgrade) upgrade_cpa_cpam ;;
    start) start_cpa_cpam ;;
    stop) stop_cpa_cpam ;;
    restart) restart_cpa_cpam ;;
    status) status_cpa_cpam ;;
    doctor) configuration_doctor ;;
    logs) logs_cpa_cpam ;;
    snapshot) create_snapshot ;;
    snapshots) list_snapshots ;;
    restore-snapshot) restore_snapshot ;;
    snapshot-delete) delete_snapshot ;;
    task-center) configure_task_center ;;
    snapshot-schedule) configure_task_center ;;
    scheduled-snapshot) run_scheduled_snapshot ;;
    scheduled-version-check) run_scheduled_version_check ;;
    keys) show_keys ;;
    reset-keys) reset_management_keys ;;
    uninstall) uninstall_cpa_cpam ;;
    codex-login) codex_login_hint ;;
    audit-consumption) consumption_audit ;;
    audit-management) management_audit ;;
    migration-assess) migration_assess ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi

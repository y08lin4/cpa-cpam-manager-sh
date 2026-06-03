#!/usr/bin/env bash
set -Eeuo pipefail

DEFAULT_INSTALL_DIR="/opt/cliproxy-cpam"
DEFAULT_CPA_HOST_PORT="8317"
DEFAULT_CPAM_HOST_PORT="18317"
CPA_IMAGE="eceasy/cli-proxy-api:latest"
CPAM_IMAGE="seakee/cpa-manager:latest"
OLD_PANEL_CONTAINER="cpa-management-center"
CPA_CONTAINER="cli-proxy-api"
CPAM_CONTAINER="cpa-manager"
CPA_INTERNAL_PORT="8317"
CPAM_INTERNAL_PORT="18317"
CPA_MANAGER_SETUP_UPSTREAM="http://cli-proxy-api:8317"

log() {
  printf '\033[1;32m[INFO]\033[0m %s\n' "$*"
}

warn() {
  printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2
}

err() {
  printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
}

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
  local default="${2:-Y}"
  local suffix
  local answer

  if [ "$default" = "Y" ]; then
    suffix="[Y/n]"
  else
    suffix="[y/N]"
  fi

  if [ -t 0 ]; then
    printf "%s %s: " "$prompt" "$suffix"
    read -r answer || answer=""
  else
    answer=""
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
  local packages=(curl git ca-certificates openssl ufw)
  local missing=()
  local package

  for package in "${packages[@]}"; do
    case "$package" in
      curl|git|openssl|ufw)
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
    docker --version || true
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
    docker compose version
    return 0
  fi

  warn "未检测到 docker compose plugin，尝试安装 docker-compose-plugin"
  command -v apt-get >/dev/null 2>&1 || die "当前系统缺少 apt-get，无法安装 docker-compose-plugin"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y docker-compose-plugin
  docker compose version >/dev/null 2>&1 || die "docker compose 不可用，请手动检查 Docker Compose 插件"
  docker compose version
}

generate_hex() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  else
    od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

generate_api_key() {
  printf 'sk-cpa-%s\n' "$(generate_hex)"
}

generate_mgt_key() {
  printf 'mgt-cpa-%s\n' "$(generate_hex)"
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

container_exists() {
  local name="$1"
  docker ps -a --format '{{.Names}}' | grep -Fxq "$name"
}

show_all_containers() {
  docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
}

detect_install_dir() {
  local env_install_dir="${INSTALL_DIR:-}"
  local container
  local detected

  if [ -n "$env_install_dir" ]; then
    printf '%s\n' "$env_install_dir"
    return 0
  fi

  for container in "$CPAM_CONTAINER" "$CPA_CONTAINER"; do
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
  local install_dir="${1:-$(detect_install_dir)}"
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

detect_cpam_port() {
  local install_dir="${1:-$(detect_install_dir)}"
  local port
  local secrets_value

  if port="$(port_from_docker_mapping "$CPAM_CONTAINER" "$CPAM_INTERNAL_PORT")"; then
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

ensure_compose_dir() {
  local install_dir="$1"
  [ -d "$install_dir" ] || die "安装目录不存在: $install_dir"
  [ -f "$install_dir/docker-compose.yml" ] || die "未找到 docker-compose.yml: $install_dir/docker-compose.yml"
}

compose_in_dir() {
  local install_dir="$1"
  shift
  (cd "$install_dir" && docker compose "$@")
}

backup_existing_files() {
  local install_dir="$1"
  local ts
  local file
  ts="$(timestamp)"

  for file in config.yaml docker-compose.yml; do
    if [ -f "$install_dir/$file" ]; then
      cp -a "$install_dir/$file" "$install_dir/$file.bak.$ts"
      log "已备份 $install_dir/$file -> $install_dir/$file.bak.$ts"
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

  cat > "$install_dir/docker-compose.yml" <<EOF
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

  cpa-manager:
    image: $CPAM_IMAGE
    container_name: cpa-manager
    restart: unless-stopped
    depends_on:
      - cli-proxy-api
    ports:
      - "$cpam_host_port:18317"
    environment:
      HTTP_ADDR: "0.0.0.0:18317"
      USAGE_DATA_DIR: "/data"
      USAGE_DB_PATH: "/data/usage.sqlite"
      USAGE_COLLECTOR_MODE: "auto"
      USAGE_BATCH_SIZE: "100"
      USAGE_POLL_INTERVAL_MS: "500"
      USAGE_QUERY_LIMIT: "50000"
      USAGE_CORS_ORIGINS: "*"
    volumes:
      - ./cpa-manager-data:/data
EOF
}

write_secrets() {
  local install_dir="$1"
  local api_key="$2"
  local mgt_key="$3"
  local cpa_host_port="$4"
  local cpam_host_port="$5"
  local server_ip="$6"
  local secrets_file="$install_dir/.secrets.txt"

  cat > "$secrets_file" <<EOF
API_KEY=$api_key
MGT_KEY=$mgt_key
CPA_API=http://$server_ip:$cpa_host_port/v1
CPA_MANAGER=http://$server_ip:$cpam_host_port/management.html
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
    log "UFW 已启用，自动放行 CPA / CPA-Manager 相关端口"
    for port in "${ports[@]}"; do
      ufw allow "${port}/tcp"
    done
    warn "请同时在云厂商安全组放行 8317/18317（或你自定义的宿主机端口）"
    return 0
  fi

  if ask_yes_no "UFW 未启用，是否启用并放行 SSH、CPA、CPA-Manager 相关端口" "N"; then
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

  for container in "$CPA_CONTAINER" "$CPAM_CONTAINER" "$OLD_PANEL_CONTAINER"; do
    if container_exists "$container"; then
      found+=("$container")
    fi
  done

  if [ "${#found[@]}" -eq 0 ]; then
    return 0
  fi

  warn "检测到已有相关容器：${found[*]}"
  show_all_containers

  if ask_yes_no "是否删除这些容器并重建" "Y"; then
    docker rm -f "${found[@]}"
  else
    die "已取消安装/重装"
  fi
}

prepare_install_dir() {
  local install_dir="$1"
  mkdir -p "$install_dir/auths" "$install_dir/logs" "$install_dir/cpa-manager-data" "$install_dir/backups"
}

create_backup_archive() {
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
    warn "没有可备份的文件"
    return 0
  fi

  (cd "$install_dir" && tar -czf "$backup_file" "${items[@]}") || die "备份失败: $backup_file"
  log "备份完成: $backup_file"
}

health_check() {
  local install_dir="$1"
  local api_key="${2:-}"
  local cpa_host_port="${3:-}"
  local cpam_host_port="${4:-}"
  local response

  if [ -z "$cpa_host_port" ]; then
    cpa_host_port="$(detect_cpa_port "$install_dir")"
  fi
  if [ -z "$cpam_host_port" ]; then
    cpam_host_port="$(detect_cpam_port "$install_dir")"
  fi
  if [ -z "$api_key" ]; then
    api_key="$(load_secrets_value "$install_dir/.secrets.txt" "API_KEY" || true)"
  fi

  log "CPA API 健康检查: http://127.0.0.1:${cpa_host_port}/v1/models"
  if [ -n "$api_key" ]; then
    if response="$(curl -sS --max-time 8 "http://127.0.0.1:${cpa_host_port}/v1/models" -H "Authorization: Bearer ${api_key}" 2>&1)"; then
      printf '%s\n' "${response:0:1000}"
    else
      warn "CPA API 健康检查失败: $response"
    fi
  else
    warn "未找到 API_KEY，跳过 CPA API 鉴权检查"
  fi

  log "CPA-Manager 健康检查: http://127.0.0.1:${cpam_host_port}/management.html"
  if ! curl -I --max-time 8 "http://127.0.0.1:${cpam_host_port}/management.html"; then
    warn "CPA-Manager 页面检查失败"
  fi
}

print_install_summary() {
  local install_dir="$1"
  local api_key="$2"
  local mgt_key="$3"
  local cpa_host_port="$4"
  local cpam_host_port="$5"
  local server_ip="$6"

  cat <<EOF

安装完成

CPA API:
http://$server_ip:$cpa_host_port/v1

CPA 自带面板:
http://$server_ip:$cpa_host_port/management.html

CPA-Manager:
http://$server_ip:$cpam_host_port/management.html

API_KEY:
$api_key

MGT_KEY:
$mgt_key

密钥已保存到：
$install_dir/.secrets.txt

首次打开 CPA-Manager 如果出现 Setup，请填：
CPA 地址: $CPA_MANAGER_SETUP_UPSTREAM
Management Key: $mgt_key
EOF
}

install_cpa_cpam() {
  local install_dir_default="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
  local cpa_port_default="${CPA_HOST_PORT:-$DEFAULT_CPA_HOST_PORT}"
  local cpam_port_default="${CPAM_HOST_PORT:-$DEFAULT_CPAM_HOST_PORT}"
  local install_dir
  local cpa_host_port
  local cpam_host_port
  local api_key
  local mgt_key
  local server_ip

  install_dir="$(read_with_default "安装目录，回车使用默认 [$install_dir_default]: " "$install_dir_default")"
  cpa_host_port="$(read_with_default "CLIProxyAPI 宿主机端口，回车使用默认 [$cpa_port_default]: " "$cpa_port_default")"
  cpam_host_port="$(read_with_default "CPA-Manager 宿主机端口，回车使用默认 [$cpam_port_default]: " "$cpam_port_default")"

  validate_port "$cpa_host_port" || die "CLIProxyAPI 宿主机端口无效: $cpa_host_port"
  validate_port "$cpam_host_port" || die "CPA-Manager 宿主机端口无效: $cpam_host_port"

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

  if [ -d "$install_dir" ] && { [ -f "$install_dir/config.yaml" ] || [ -f "$install_dir/docker-compose.yml" ]; }; then
    if ! ask_yes_no "检测到已有安装文件，是否继续安装/重装并覆盖配置" "Y"; then
      die "已取消安装/重装"
    fi
  fi

  pre_install_cleanup
  prepare_install_dir "$install_dir"
  backup_existing_files "$install_dir"
  write_config_yaml "$install_dir" "$api_key" "$mgt_key"
  write_compose_yaml "$install_dir" "$cpa_host_port" "$cpam_host_port"
  server_ip="$(get_server_ip)"
  write_secrets "$install_dir" "$api_key" "$mgt_key" "$cpa_host_port" "$cpam_host_port" "$server_ip"
  handle_firewall "$cpa_host_port" "$cpam_host_port"

  log "拉取镜像并启动容器"
  compose_in_dir "$install_dir" pull || die "docker compose pull 失败"
  compose_in_dir "$install_dir" up -d || die "docker compose up -d 失败"
  sleep 8
  show_all_containers
  health_check "$install_dir" "$api_key" "$cpa_host_port" "$cpam_host_port"
  print_install_summary "$install_dir" "$api_key" "$mgt_key" "$cpa_host_port" "$cpam_host_port" "$server_ip"
}

upgrade_cpa_cpam() {
  local detected_dir
  local install_dir
  local backup_file

  detected_dir="$(detect_install_dir)"
  show_all_containers
  install_dir="$(read_with_default "安装目录，回车使用检测值 [$detected_dir]: " "$detected_dir")"
  ensure_compose_dir "$install_dir"

  backup_file="$install_dir/backups/pre-upgrade-$(timestamp).tar.gz"
  create_backup_archive "$install_dir" "$backup_file" docker-compose.yml config.yaml .secrets.txt auths cpa-manager-data

  log "升级 CPA + CPA-Manager"
  compose_in_dir "$install_dir" pull || die "docker compose pull 失败"
  compose_in_dir "$install_dir" up -d || die "docker compose up -d 失败"
  sleep 8
  show_all_containers
  health_check "$install_dir"
}

start_cpa_cpam() {
  local install_dir
  install_dir="$(detect_install_dir)"
  ensure_compose_dir "$install_dir"
  compose_in_dir "$install_dir" up -d || die "启动失败"
}

stop_cpa_cpam() {
  local install_dir
  install_dir="$(detect_install_dir)"
  ensure_compose_dir "$install_dir"
  compose_in_dir "$install_dir" stop || die "停止失败"
}

restart_cpa_cpam() {
  local install_dir
  install_dir="$(detect_install_dir)"
  ensure_compose_dir "$install_dir"
  compose_in_dir "$install_dir" restart || die "重启失败"
}

status_cpa_cpam() {
  local install_dir
  local cpa_host_port
  local cpam_host_port

  install_dir="$(detect_install_dir)"
  cpa_host_port="$(detect_cpa_port "$install_dir")"
  cpam_host_port="$(detect_cpam_port "$install_dir")"

  cat <<EOF
检测到的安装目录: $install_dir
CPA 端口: $cpa_host_port
CPA-Manager 端口: $cpam_host_port

容器状态:
EOF
  show_all_containers
  printf '\n健康检查结果:\n'
  health_check "$install_dir" "" "$cpa_host_port" "$cpam_host_port"
}

logs_cpa_cpam() {
  local choice
  cat <<'EOF'
请选择要查看的日志：
1) cli-proxy-api
2) cpa-manager
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
    2) docker logs -f --tail=120 "$CPAM_CONTAINER" ;;
    3)
      printf '\n===== %s =====\n' "$CPA_CONTAINER"
      docker logs --tail=120 "$CPA_CONTAINER" || true
      printf '\n===== %s =====\n' "$CPAM_CONTAINER"
      docker logs --tail=120 "$CPAM_CONTAINER" || true
      ;;
    *) warn "无效选项" ;;
  esac
}

backup_cpa_cpam() {
  local install_dir
  local backup_file

  install_dir="$(detect_install_dir)"
  ensure_compose_dir "$install_dir"
  backup_file="$install_dir/backups/cpa-cpam-backup-$(timestamp).tar.gz"
  create_backup_archive "$install_dir" "$backup_file" docker-compose.yml config.yaml .secrets.txt auths logs cpa-manager-data
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

  if ! ask_yes_no "确认卸载 CPA + CPA-Manager" "N"; then
    log "已取消卸载"
    return 0
  fi

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

print_help() {
  cat <<'EOF'
用法：
  bash cpa-cpam-manager.sh [命令]

命令：
  menu       交互菜单
  install    安装 / 重装 CPA + CPA-Manager
  upgrade    升级 CPA + CPA-Manager
  start      启动
  stop       停止
  restart    重启
  status     状态 / 健康检查
  logs       查看日志
  backup     备份
  keys       查看密钥 / 地址
  uninstall  卸载
  help       显示帮助

可用环境变量：
  INSTALL_DIR=/opt/cliproxy-cpam
  CPA_HOST_PORT=8317
  CPAM_HOST_PORT=18317
  API_KEY=sk-cpa-xxx
  MGT_KEY=mgt-cpa-xxx
EOF
}

menu_loop() {
  local choice
  while true; do
    cat <<'EOF'

CLIProxyAPI + CPA-Manager 运维脚本

1) 安装 / 重装 CPA + CPA-Manager
2) 升级 CPA + CPA-Manager
3) 启动
4) 停止
5) 重启
6) 状态 / 健康检查
7) 查看日志
8) 备份
9) 查看密钥 / 地址
10) Codex OAuth 登录命令提示
11) 卸载
0) 退出
EOF
    printf "请输入选项: "
    read -r choice || choice="0"
    case "$choice" in
      1) install_cpa_cpam ;;
      2) upgrade_cpa_cpam ;;
      3) start_cpa_cpam ;;
      4) stop_cpa_cpam ;;
      5) restart_cpa_cpam ;;
      6) status_cpa_cpam ;;
      7) logs_cpa_cpam ;;
      8) backup_cpa_cpam ;;
      9) show_keys ;;
      10) codex_login_hint ;;
      11) uninstall_cpa_cpam ;;
      0) log "已退出"; break ;;
      *) warn "无效选项" ;;
    esac
  done
}

main() {
  local command_name="${1:-menu}"

  need_root

  case "$command_name" in
    help|-h|--help)
      print_help
      return 0
      ;;
    menu|install|upgrade|start|stop|restart|status|logs|backup|keys|uninstall|codex-login)
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
    logs) logs_cpa_cpam ;;
    backup) backup_cpa_cpam ;;
    keys) show_keys ;;
    uninstall) uninstall_cpa_cpam ;;
    codex-login) codex_login_hint ;;
  esac
}

main "$@"

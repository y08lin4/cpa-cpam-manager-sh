# CPA Manager Plus 一键安装与运维脚本

面向 Debian / Ubuntu VPS 的 CLIProxyAPI + CPA Manager Plus 部署与生命周期管理工具。

项目提供一键安装、升级、状态检查、日志查看、备份恢复、Codex OAuth 登录提示，以及从旧 CPA-Manager 到 CPA Manager Plus 的安全迁移。脚本会在交互菜单顶部实时展示容器、镜像版本、运行状态和端口映射。

## 项目定位

本项目适合以下场景：

- 在新服务器上一键部署 CLIProxyAPI 与 CPA Manager Plus。
- 使用单个 Bash 脚本完成日常启动、停止、升级、日志和备份操作。
- 将本项目早期部署的旧 `seakee/cpa-manager` 原地迁移到 Plus。
- 保持 CPA API 服务运行，仅短暂停止 Manager 完成 SQLite 一致性迁移。
- 为非专业运维用户提供带状态摘要和安全确认的交互菜单。

本项目不是 CPA 或 CPA Manager Plus 的上游源码仓库：

- [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)
- [CPA Manager Plus](https://github.com/seakee/CPA-Manager-Plus)

## 核心能力

- 新部署默认使用 `seakee/cpa-manager-plus:latest`。
- 自动安装或检查 Docker、Docker Compose 和基础依赖。
- 自动生成并保存 API Key、CPA Management Key 和 Plus 管理员密钥。
- 实时显示容器、镜像版本、运行状态和端口映射。
- 识别 `legacy`、`plus`、`mixed`、`cpa-only` 和 `not-installed` 状态。
- 提供只读迁移预检、dry-run、正式迁移、自动回滚和手工回滚。
- 升级前自动备份配置、认证数据和 Manager 数据。
- 检查 CPA API、Plus `/health`、兼容端点和鉴权状态。
- 提供日志、密钥查看、Codex OAuth、卸载和 UFW 端口管理。

## 部署结构

```text
客户端
  │
  ├── :8317/v1 ──────────────> CLIProxyAPI
  │                              │
  │                              │ Management API / Usage Queue
  │                              ▼
  └── :18317/management.html -> CPA Manager Plus
                                  │
                                  └── /data
                                      ├── usage.sqlite
                                      ├── usage.sqlite-wal
                                      ├── usage.sqlite-shm
                                      └── data.key
```

默认容器：

| 服务 | 容器 | 镜像 | 默认端口 |
| --- | --- | --- | --- |
| CLIProxyAPI | `cli-proxy-api` | `eceasy/cli-proxy-api:latest` | `8317` |
| CPA Manager Plus | `cpa-manager-plus` | `seakee/cpa-manager-plus:latest` | `18317` |

默认安装目录：`/opt/cliproxy-cpam`。

## 系统要求

- Debian 或 Ubuntu。
- `root` 用户运行。
- 可以访问 Docker 镜像仓库和脚本下载地址。
- 云安全组允许所需端口。
- 正式迁移旧 Manager 时，旧部署必须是本脚本生成的标准 bind mount 结构。

## 快速开始

### 一键运行

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/y08lin4/cpa-cpam-manager-sh/main/cpa-cpam-manager.sh)
```

脚本会进入交互菜单。新服务器选择：

```text
1) 安装 / 重装 CPA + CPA Manager Plus
```

### 下载后运行

```bash
git clone https://github.com/y08lin4/cpa-cpam-manager-sh.git
cd cpa-cpam-manager-sh
chmod +x cpa-cpam-manager.sh
./cpa-cpam-manager.sh
```

### 非交互命令

```bash
bash cpa-cpam-manager.sh install
bash cpa-cpam-manager.sh status
bash cpa-cpam-manager.sh backup
```

## 菜单状态摘要

交互菜单每次刷新都会读取 Docker 的真实状态：

```text
服务状态
────────────────────────────────────────────────────────
✓  CLIProxyAPI
   状态：运行中
   镜像：eceasy/cli-proxy-api:latest
   端口：8317 -> 8317/tcp

✓  CPA Manager Plus
   状态：运行中
   镜像：seakee/cpa-manager-plus:latest
   端口：18317 -> 18317/tcp
```

运行中显示绿色 `✓`，停止或异常显示红色 `✗`，未安装或旧版提示显示黄色 `!`。设置 `NO_COLOR=1` 可以关闭 ANSI 颜色。

若同时发现新旧 Manager，脚本会显示告警并阻止安装、升级和迁移，避免两个 Manager 同时消费一个 CPA 用量队列。

## 命令参考

| 命令 | 说明 |
| --- | --- |
| `menu` | 打开交互菜单 |
| `install` | 安装或重装 CPA + CPA Manager Plus |
| `upgrade` | 备份后拉取镜像并升级 Plus 部署 |
| `preflight` | 只读检查旧安装、挂载和迁移条件 |
| `migrate --dry-run` | 输出迁移计划，不修改文件或停止容器 |
| `migrate` | 正式迁移旧 CPA-Manager，并在失败时自动回滚 |
| `rollback` | 恢复最近一次迁移前快照 |
| `start` | 启动 Compose 服务 |
| `stop` | 停止 Compose 服务 |
| `restart` | 重启 Compose 服务 |
| `status` | 显示安装类型、容器状态和健康检查 |
| `logs` | 查看 CPA 或当前 Manager 日志 |
| `backup` | 创建完整运维备份 |
| `keys` | 显示密钥和访问地址 |
| `codex-login` | 输出 Codex OAuth 登录命令提示 |
| `uninstall` | 卸载服务，可选择保留数据 |
| `help` | 显示命令帮助 |

## 安装配置

可以通过环境变量覆盖默认值：

```bash
INSTALL_DIR='/opt/cliproxy-cpam' \
CPA_HOST_PORT='8317' \
CPAM_HOST_PORT='18317' \
API_KEY='sk-cpa-xxx' \
MGT_KEY='mgt-cpa-xxx' \
CPAMP_ADMIN_KEY='cpamp_xxx' \
bash cpa-cpam-manager.sh install
```

| 环境变量 | 默认值 | 说明 |
| --- | --- | --- |
| `INSTALL_DIR` | `/opt/cliproxy-cpam` | 安装和数据目录 |
| `CPA_HOST_PORT` | `8317` | CPA API 宿主机端口 |
| `CPAM_HOST_PORT` | `18317` | Plus 宿主机端口 |
| `API_KEY` | 自动生成 | 客户端调用 CPA API 的密钥 |
| `MGT_KEY` | 自动生成 | CPA Management API 密钥 |
| `CPAMP_ADMIN_KEY` | 自动生成 | Plus 登录和管理 API 密钥 |
| `CPAM_IMAGE` | `seakee/cpa-manager-plus:latest` | Plus 镜像，可指定版本 tag |

自动生成的密钥格式：

- `API_KEY`：`sk-cpa-` + 48 位十六进制随机值。
- `MGT_KEY`：`mgt-cpa-` + 48 位十六进制随机值。
- `CPAMP_ADMIN_KEY`：`cpamp_` + 48 位十六进制随机值。

## 访问地址与首次配置

```text
CPA API:             http://服务器IP:8317/v1
CPA 自带管理页面:    http://服务器IP:8317/management.html
CPA Manager Plus:    http://服务器IP:18317/management.html
```

首次打开 CPA Manager Plus 时填写：

```text
管理员密钥: CPAMP_ADMIN_KEY
CPA 地址: http://cli-proxy-api:8317
CPA Management Key: MGT_KEY
```

两类管理密钥用途不同：

| 密钥 | 用途 |
| --- | --- |
| `MGT_KEY` | Plus 连接 CPA Management API |
| `CPAMP_ADMIN_KEY` | 登录 Plus 和调用 Plus 管理 API |

CPA 可能会把 `config.yaml` 中的 `remote-management.secret-key` 转为 bcrypt hash。若 `.secrets.txt` 丢失，无法从该 hash 反推出原始 `MGT_KEY`。

## 从旧 CPA-Manager 迁移

### 1. 只读预检

```bash
bash cpa-cpam-manager.sh preflight
```

预检会展示：

- 当前安装类型和安装目录。
- 新旧 Manager 容器、镜像和状态。
- `/data` 实际挂载来源。
- CPA 用量统计和远程管理配置。
- 是否允许进入自动迁移流程。

### 2. 查看迁移计划

```bash
bash cpa-cpam-manager.sh migrate --dry-run
```

该命令不会停止容器，也不会修改 Compose、密钥或数据。

### 3. 正式迁移

```bash
bash cpa-cpam-manager.sh migrate
```

迁移流程：

1. 校验临时 Plus Compose。
2. 仅停止旧 `cpa-manager`，CPA API 保持运行。
3. 备份并校验 Compose、密钥和完整 `cpa-manager-data`。
4. 保持原 `/data`、访问地址和 `18317` 端口不变。
5. 启动 `cpa-manager-plus`。
6. 验证 `/health`、`/usage-service/info`、鉴权 `/status` 和 `data.key`。
7. 验证失败时自动恢复迁移前快照。
8. 验证成功后生成迁移后备份。

### 4. 手工回滚

```bash
bash cpa-cpam-manager.sh rollback
```

回滚会恢复最近一次迁移前的 Compose、密钥和完整 Manager 数据。Plus 失败现场会保留为带时间戳的目录，方便排查。

### 当前迁移边界

自动迁移仅支持本项目生成的标准挂载：

```text
<安装目录>/cpa-manager-data -> /data
```

Docker named volume、自定义宿主机目录或无法确认的数据挂载会被安全阻断，不会尝试猜测或移动数据。详细设计见 [迁移与项目演进规划](docs/CPA_MANAGER_PLUS_ROADMAP.md)。

## 日常运维

### 升级

```bash
bash cpa-cpam-manager.sh upgrade
```

升级前自动创建：

```text
/opt/cliproxy-cpam/backups/pre-upgrade-YYYY-MM-DD-HHMMSS.tar.gz
```

旧 CPA-Manager 必须使用 `migrate`，不能通过 `upgrade` 绕过迁移保护。

### 查看状态

```bash
bash cpa-cpam-manager.sh status
```

状态命令会检查 CPA `/v1/models`、Plus `/health`、`/usage-service/info`、鉴权 `/status` 和管理页面。

### 查看日志

```bash
bash cpa-cpam-manager.sh logs
```

脚本会自动选择 `cpa-manager-plus` 或旧 `cpa-manager`。

### 备份

```bash
bash cpa-cpam-manager.sh backup
```

为避免 SQLite、认证文件或日志在打包过程中发生变化，脚本会短暂停止 Manager 和 CLIProxyAPI，完成归档与可读性校验后自动恢复原运行状态。迁移后的补充快照只暂停 Manager，不影响 CPA API。

常规备份路径：

```text
/opt/cliproxy-cpam/backups/cpa-cpam-backup-YYYY-MM-DD-HHMMSS.tar.gz
```

迁移备份路径：

```text
/opt/cliproxy-cpam/backups/migration-YYYY-MM-DD-HHMMSS/
├── manifest.env
├── legacy-container-inspect.json
├── pre-migration.tar.gz
├── post-migration.tar.gz
└── plus-failed.log（仅失败时）
```

Plus 备份必须包含 `/data/data.key`。该文件丢失后，SQLite 中加密保存的 CPA Management Key 无法解密。

### Codex OAuth 登录

```bash
bash cpa-cpam-manager.sh codex-login
```

脚本会输出容器内登录命令。按 CLIProxyAPI 提示，在本地电脑建立 SSH 隧道并完成浏览器授权。

### 卸载

```bash
bash cpa-cpam-manager.sh uninstall
```

卸载时可以选择：

- 保留数据：仅执行 `docker compose down`。
- 删除数据：再次确认后删除安装目录。

脚本会拒绝删除 `/`、`/opt`、`/root` 等危险路径。

## 安装目录

```text
/opt/cliproxy-cpam/
├── docker-compose.yml
├── config.yaml
├── .secrets.txt
├── auths/
├── logs/
├── cpa-manager-data/
│   ├── usage.sqlite
│   └── data.key
└── backups/
```

| 路径 | 说明 |
| --- | --- |
| `config.yaml` | CLIProxyAPI 配置 |
| `.secrets.txt` | API、CPA 管理和 Plus 管理密钥，权限 `0600` |
| `auths/` | OAuth 与认证文件 |
| `logs/` | CLIProxyAPI 文件日志 |
| `cpa-manager-data/` | Plus SQLite、WAL、SHM 和数据加密密钥 |
| `backups/` | 升级、常规备份和迁移快照 |

## 端口与防火墙

脚本涉及以下 TCP 端口：

| 端口 | 用途 |
| --- | --- |
| `8317` | CPA API 与 CPA 管理页面 |
| `18317` | CPA Manager Plus |
| `8085`、`1455`、`54545`、`51121`、`11451` | CLIProxyAPI OAuth 回调或兼容端口 |

若 UFW 已启用，脚本会自动添加规则。若 UFW 未启用，脚本不会默认开启，以免锁定 SSH；只有用户明确确认后才会放行 SSH 和相关服务端口并启用 UFW。

云厂商安全组仍需单独配置。

## 安全建议

- 不要提交或公开 `.secrets.txt`。
- 不要在 Issue、聊天、截图或日志中暴露任何密钥。
- 将 `.secrets.txt` 权限保持为 `0600`。
- 对公网部署建议使用反向代理、HTTPS 和访问控制。
- 迁移、升级前确认备份目录有足够空间。
- 不要让两个 Manager 同时消费同一个 CPA 用量队列。
- 生产环境可以通过 `CPAM_IMAGE` 固定经过验证的镜像版本，而不是长期跟随 `latest`。

## 常见问题

### 菜单显示 `mixed`

同时存在 `cpa-manager` 和 `cpa-manager-plus`。脚本会阻断高风险操作，请确认只保留一个 Manager 消费用量队列。

### 迁移提示 `/data` 不是标准挂载

当前部署使用 named volume 或自定义宿主机目录。脚本不会猜测数据位置，需要先人工确认数据与回滚方案。

### Plus 登录返回 401

确认使用的是 `CPAMP_ADMIN_KEY`。`MGT_KEY` 是 CPA Management Key，不能用于登录 Plus。

### 迁移后看不到历史数据

确认 Plus 挂载的是原 `cpa-manager-data`，而不是新的空目录或空 volume，并检查迁移日志和 `/status`。

### `data.key` 丢失

优先从完整备份恢复。若无法恢复，SQLite 中已加密保存的 CPA Management Key 无法解密，需要重新配置 CPA 连接。

### `.secrets.txt` 丢失

CPA 配置中的 Management Key 可能已是 bcrypt hash，不能反推明文。应从备份恢复或重新设置密钥。

## 开发与检查

提交前至少执行：

```bash
bash -n cpa-cpam-manager.sh
git diff --check
```

如本机已安装，建议同时执行：

```bash
shellcheck cpa-cpam-manager.sh
shfmt -d cpa-cpam-manager.sh
```

## 许可证与上游

本项目仅维护安装与运维脚本。CLIProxyAPI、CPA Manager Plus 及相关镜像的许可证、发布节奏和功能行为以各自上游项目为准。

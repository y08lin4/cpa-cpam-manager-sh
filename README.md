# CPA Manager Plus 一键安装与运维脚本

面向 Debian / Ubuntu VPS 的 CLIProxyAPI + CPA Manager Plus 部署与生命周期管理工具。

项目提供一键安装、升级、状态检查、日志查看、快照创建与恢复、Codex OAuth 登录提示，以及从旧 CPA-Manager 到 CPA Manager Plus 的安全迁移。脚本会在交互菜单顶部实时展示容器、镜像版本、运行状态和端口映射。

## 项目定位

本项目适合以下场景：

- 在新服务器上一键部署 CLIProxyAPI 与 CPA Manager Plus。
- 使用单个 Bash 脚本完成日常启动、停止、升级、日志和快照操作。
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
- 提供可备注、可查看、可恢复的快照管理，以及升级、迁移和密钥重置前的自动保护点。
- 检查 CPA API、Plus `/health`、兼容端点和鉴权状态。
- 将消费行为与管理行为拆成两个一级审计入口，两套审计分别展示成功和失败 IP。
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
bash cpa-cpam-manager.sh snapshot
bash cpa-cpam-manager.sh snapshots
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
| `upgrade` | 创建保护快照后拉取镜像并升级 Plus 部署 |
| `migration-assess` | 一次完成迁移条件检查并显示迁移计划，全程只读 |
| `migrate` | 正式迁移旧 CPA-Manager，并在失败时自动回滚 |
| `rollback` | 恢复最近一次迁移前快照 |
| `audit-consumption` | 消费行为审计，分别显示消费成功和消费失败 IP 排名 |
| `audit-management` | 管理行为审计，分别显示管理成功、失败 IP 排名和操作明细 |
| `start` | 启动 Compose 服务 |
| `stop` | 停止 Compose 服务 |
| `restart` | 重启 Compose 服务 |
| `status` | 显示安装类型、容器状态和健康检查 |
| `doctor` | 只读检查 Compose、配置、端口、权限、SQLite、挂载和磁盘 |
| `logs` | 查看 CPA 或当前 Manager 日志 |
| `snapshot` | 创建带可选备注的人工快照 |
| `snapshots` | 按时间、类型、模式和大小查看现有快照 |
| `restore-snapshot` | 选择并恢复快照，失败时自动回退 |
| `snapshot-delete` | 按编号删除指定人工或定时快照 |
| `snapshot-schedule` | 配置 systemd 自动定时快照和滚动保留 |
| `keys` | 显示密钥和访问地址 |
| `reset-keys` | 重新生成 Plus 管理员密钥、CPA Management Key 或两者 |
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
| `CPA_IMAGE` | `eceasy/cli-proxy-api:latest` | CLIProxyAPI 镜像，可指定版本 tag |
| `ASSUME_YES` | `0` | 设为 `1` 时自动确认高风险操作，仅用于可信自动化环境 |
| `CONFIRM_DEFAULT` | `Y` | 全局确认默认值；直接按 Enter 确认，设为 `N` 可恢复保守默认 |
| `IP_API_BATCH_URL` | `http://ip-api.com/batch` | 访客公网 IP 批量归属查询接口；可替换为兼容的 HTTPS 端点 |

自动生成的密钥格式：

`CONFIRM_DEFAULT=Y` 只控制交互终端中直接按 Enter 的行为。cron、管道等非交互环境不会自动确认；可信自动化必须显式设置 `ASSUME_YES=1`。

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

### 1. 迁移评估

```bash
bash cpa-cpam-manager.sh migration-assess
```

迁移评估在一次只读执行中同时展示：

- 当前安装类型和安装目录。
- 新旧 Manager 容器、镜像和状态。
- `/data` 实际挂载来源。
- CPA 用量统计和远程管理配置。
- 是否允许进入自动迁移流程。
- 完整迁移步骤、停机范围、验证项目和回滚方式。

该命令不会停止容器，也不会修改 Compose、密钥或数据。旧 `preflight` 命令已删除；`migrate --dry-run` 作为正式迁移命令的只读参数暂时转发到同一评估逻辑，不会形成独立菜单入口。

### 2. 正式迁移

```bash
bash cpa-cpam-manager.sh migrate
```

迁移流程：

1. 校验临时 Plus Compose。
2. 仅停止旧 `cpa-manager`，CPA API 保持运行。
3. 创建并校验包含 Compose、密钥和完整 `cpa-manager-data` 的迁移快照。
4. 保持原 `/data`、访问地址和 `18317` 端口不变。
5. 启动 `cpa-manager-plus`。
6. 验证 `/health`、`/usage-service/info`、鉴权 `/status` 和 `data.key`。
7. 验证失败时自动恢复迁移前快照。
8. 验证成功后生成迁移后快照。

### 3. 手工回滚

```bash
bash cpa-cpam-manager.sh rollback
```

回滚会恢复最近一次迁移前的 Compose、密钥和完整 Manager 数据。Plus 失败现场会保留为带时间戳的目录，方便排查。

### 当前迁移边界

自动迁移仅支持本项目生成的标准挂载：

```text
<安装目录>/cpa-manager-data -> /data
```

Docker named volume、自定义宿主机目录或无法确认的数据挂载会被安全阻断，不会尝试猜测或移动数据。近期实施路线见 [CLIProxyAPI 与 CPA Manager Plus 功能路线图](ROADMAP.md)，更完整的 50 余项产品构思见 [后续功能构思](docs/FUTURE_FEATURE_IDEAS.md)，现有功能应该保留、合并、拆分、删除或新增的决策见 [功能整合与优化规划](docs/FEATURE_GOVERNANCE_PLAN.md)。消费行为、管理行为两套审计及无损清除方案见 [行为审计与无损清除设计稿](AUDIT_DESIGN.md)。

## 日常运维

### 升级

```bash
bash cpa-cpam-manager.sh upgrade
```

升级不会直接重建容器，而是先执行版本检查：

1. 读取两个运行容器当前使用的镜像版本和 Image ID。
2. 拉取相同镜像引用在仓库中的最新版本，不影响当前容器。
3. 优先展示 OCI 语义版本；无版本标签时展示 tag、revision 和短 Image ID。
4. 对比当前与目标 Image ID，明确标记“可升级”或“已是最新”。
5. 展示安装目录、系统快照位置、短暂停机影响和数据保留策略。
6. 用户明确确认后创建一致性保护快照并重新创建服务。

若两个服务均为最新镜像，脚本默认退出，不会无意义重建容器。

### 消费行为与管理行为审计

```bash
bash cpa-cpam-manager.sh audit-consumption
bash cpa-cpam-manager.sh audit-management
```

审计功能读取最近 24 小时的 CLIProxyAPI、CPA Manager Plus 容器日志和 CLIProxyAPI 文件日志，但两套结果完全分开：

- 消费行为审计只统计 `/v1/chat/completions`、`/v1/responses`、图像、视频、Gemini 和 Codex 等实际模型消费路径，分别输出“消费成功 IP 排名”和“消费失败 IP 排名”。
- 管理行为审计只统计 `/v0/management/*`、Plus 配置、处理策略、配额冷却和初始化等管理路径，分别输出“管理操作成功 IP 排名”和“管理操作失败 IP 排名”，并额外展示方法、路径和结果汇总。

`/health`、`/status`、`/v1/models`、管理页面和静态资源只计入过滤数量，不进入任何榜单；无法分类的路径只显示诊断数量，也不会混入消费或管理审计。HTTP 2xx 计为成功，HTTP 4xx/5xx 计为失败。公网、内网和回环地址都会在本地统计，401、403 会在所属行为审计中单独提示。

经用户确认后，脚本会把两张榜单前 30 名中去重后的公网 IP 通过 [IP-API Batch](https://ip-api.com/docs/api:batch) 批量查询国家、地区、城市、ASN、运营商、代理和机房标记。单批最多发送 100 个公网 IP；内网和回环地址不会发送。免费 Batch 端点使用 HTTP，脚本会在调用前明确提示这一隐私与传输风险；接口失败或限流不会影响本地排行榜。

解析器同时支持 CLIProxyAPI 的 Gin 访问日志格式和 Plus 的 `http 方法 路径 status=... remote=...` 官方格式。旧混合菜单和 `security` 命令已经删除，不再保留可能误解为混合统计的入口。

升级前自动创建：

```text
/opt/cliproxy-cpam/snapshots/system/pre-upgrade-YYYY-MM-DD-HHMMSS/
├── metadata.env
└── snapshot.tar.gz
```

旧 CPA-Manager 必须使用 `migrate`，不能通过 `upgrade` 绕过迁移保护。

### 查看状态

```bash
bash cpa-cpam-manager.sh status
```

状态命令会检查 CPA `/v1/models`、Plus `/health`、`/usage-service/info`、鉴权 `/status` 和管理页面。

菜单状态、状态检查、升级检查和迁移评估共用同一个只读运行状态采集器，安装类型、容器、镜像、镜像 ID、运行状态和端口不会再由不同功能分别推断。

### 配置体检

```bash
bash cpa-cpam-manager.sh doctor
```

配置体检不会自动修改文件。它会检查 Compose 解析、CLIProxyAPI 关键配置、主端口、`.secrets.txt` 与 `data.key` 权限、SQLite `quick_check`、Manager `/data` 挂载、快照目录权限、磁盘空间，以及新旧 Manager 是否冲突。存在错误时命令返回非零；警告项只提示人工确认。

### 查看日志

```bash
bash cpa-cpam-manager.sh logs
```

脚本会自动选择 `cpa-manager-plus` 或旧 `cpa-manager`。

### 快照管理

```bash
bash cpa-cpam-manager.sh snapshot
bash cpa-cpam-manager.sh snapshots
bash cpa-cpam-manager.sh restore-snapshot
bash cpa-cpam-manager.sh snapshot-delete
bash cpa-cpam-manager.sh snapshot-schedule
```

创建快照时备注可直接回车跳过，并可选择两种模式：

- 快速不停机快照（默认）：服务保持运行，保存 Compose、配置、密钥和认证文件，并通过 Python SQLite 在线快照 API 生成可校验的 `usage.sqlite` 时间点快照；不包含运行日志。
- 完整一致性快照：短暂停止 Manager 和 CLIProxyAPI，保存配置、凭证和完整 Manager 数据，适合重大变更前保护和灾难恢复。

安装成功后，脚本自动创建备注为“初始安装”的系统快照。升级、密钥重置和人工恢复前也会自动建立系统保护点。人工快照、系统保护点和迁移快照统一使用 v3 `metadata.env`，记录快照类型、触发原因、保护点标识、时间、大小、SHA-256、主归档、脚本版本、镜像与摘要、包含内容和恢复范围，并通过同一套元数据与校验逻辑验证归档完整性。快速快照中的认证文件属于尽力快照，后续新增数据会进入下一次快照；原始日志不进入普通快照，恢复时也不会删除日志。

“删除指定快照”按列表编号选择，只允许删除受管的人工快照或 `scheduled-*` 定时快照。初始安装、升级前、密钥重置前和恢复前系统保护点不能通过普通入口删除。

“定时快照设置”会安装并启用 systemd timer，可选择每天或每周创建快速不停机快照，并设置保留最近 1-100 个自动快照。滚动清理只处理 `scheduled-*`；人工快照、系统保护点和迁移快照不会被自动删除。

定时任务使用安装目录 `bin/` 中的受管脚本副本。更新本仓库脚本后应重新运行一次 `snapshot-schedule`，让定时任务同步使用新版本。卸载服务时脚本会自动停用并删除对应 systemd timer。

快照列表使用固定列展示编号、类型、创建时间、模式、大小和备注。每个快照使用独立目录，归档与元数据不会混在一起：

```text
/opt/cliproxy-cpam/snapshots/
├── manual/
│   └── manual-YYYY-MM-DD-HHMMSS/
│       ├── metadata.env
│       └── snapshot.tar.gz
├── system/
│   ├── initial-install-YYYY-MM-DD-HHMMSS/
│   ├── pre-upgrade-YYYY-MM-DD-HHMMSS/
│   ├── pre-key-reset-YYYY-MM-DD-HHMMSS/
│   ├── pre-restore-YYYY-MM-DD-HHMMSS/
│   └── scheduled-YYYY-MM-DD-HHMMSS/
└── migration/
```

恢复前会校验压缩包 SHA-256，并拒绝路径穿越或未知顶层文件；确认页会展示目标时间与备注。恢复后会验证 Plus 健康端点和 CPA 模型接口；若文件替换、容器重建或健康验证失败，脚本会尝试恢复操作前文件并重新启动原部署。

迁移快照路径：

```text
/opt/cliproxy-cpam/snapshots/migration/migration-YYYY-MM-DD-HHMMSS/
├── metadata.env
├── legacy-container-inspect.json
├── pre-migration.tar.gz
├── post-migration.tar.gz
└── plus-failed.log（仅失败时）
```

Plus 快照必须包含 `/data/data.key`。该文件丢失后，SQLite 中加密保存的 CPA Management Key 无法解密。

### 重新生成管理密钥

```bash
bash cpa-cpam-manager.sh reset-keys
```

可以选择只重置 CPA Manager Plus 管理员密钥、只重置 CPA Management Key，或两个全部重置。脚本会自动生成高强度随机密钥，先创建完整一致性快照，再按 CPA Manager Plus 官方 `reset-admin-key` 命令更新登录凭证，并同步更新 CLIProxyAPI 与 Plus 的连接配置。

只有接口验证全部通过后才会显示新密钥；失败时自动恢复旧配置和旧数据。旧密钥以摘要形式保存时无法找回明文，只能从 `.secrets.txt` 或快照查看；不存在可用明文时应执行重新生成。

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
├── snapshots/
│   ├── manual/
│   ├── system/
│   └── migration/
├── bin/
│   └── cpa-cpam-manager.sh（启用定时快照后生成）
└── state/
    ├── snapshot-schedule.env
    └── snapshot.lock
```

| 路径 | 说明 |
| --- | --- |
| `config.yaml` | CLIProxyAPI 配置 |
| `.secrets.txt` | API、CPA 管理和 Plus 管理密钥，权限 `0600` |
| `auths/` | OAuth 与认证文件 |
| `logs/` | CLIProxyAPI 文件日志 |
| `cpa-manager-data/` | Plus SQLite、WAL、SHM 和数据加密密钥 |
| `snapshots/manual/` | 用户主动创建的快照，每份使用独立目录 |
| `snapshots/system/` | 安装、升级、密钥重置、恢复前保护点和定时快照 |
| `snapshots/migration/` | 旧 Manager 迁移前后文件和诊断材料 |
| `bin/` | systemd 定时任务使用的受管脚本副本 |
| `state/` | 定时快照策略和并发锁文件，权限受限 |

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
- 创建快照、迁移或升级前确认快照目录有足够空间。
- 不要让两个 Manager 同时消费同一个 CPA 用量队列。
- 生产环境可以通过 `CPAM_IMAGE` 固定经过验证的镜像版本，而不是长期跟随 `latest`。

## 常见问题

### 菜单显示 `mixed`

同时存在 `cpa-manager` 和 `cpa-manager-plus`。脚本会阻断高风险操作，请确认只保留一个 Manager 消费用量队列。

### 迁移提示 `/data` 不是标准挂载

当前部署使用 named volume 或自定义宿主机目录。脚本不会猜测数据位置，需要先人工确认数据与回滚方案。

### Plus 登录返回 401

确认使用的是 `CPAMP_ADMIN_KEY`。`MGT_KEY` 是 CPA Management Key，不能用于登录 Plus。当前保存的密钥无效或已经丢失时，运行 `bash cpa-cpam-manager.sh reset-keys`，选择只重置 Plus 管理员密钥或两个全部重置。

### 迁移后看不到历史数据

确认 Plus 挂载的是原 `cpa-manager-data`，而不是新的空目录或空 volume，并检查迁移日志和 `/status`。

### `data.key` 丢失

优先从完整一致性快照恢复。若无法恢复，SQLite 中已加密保存的 CPA Management Key 无法解密，需要重新配置 CPA 连接。

### `.secrets.txt` 丢失

CPA 配置中的 Management Key 可能已是 bcrypt hash，不能反推明文。应从快照恢复，或运行 `reset-keys` 重新生成并验证新的管理密钥。

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

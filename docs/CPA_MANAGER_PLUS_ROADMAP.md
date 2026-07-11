# CPA Manager Plus 迁移与项目演进规划

> 文档状态：阶段 1-4 已实现，阶段 5 待推进
>
> 编写日期：2026-07-12
>
> 适用项目：`cpa-cpam-manager-sh`
>
> 参考资料：[从 CPA-Manager 迁移](https://seakee.github.io/CPA-Manager-Plus/docs/migration/from-cpa-manager.html)、[CPA Manager Plus Docker 部署](https://seakee.github.io/CPA-Manager-Plus/docs/deployment/docker.html)

## 1. 规划结论

本项目应从“CPA + 旧 CPA-Manager 安装脚本”演进为“CPA + CPA Manager Plus 生命周期管理脚本”，并采用以下策略：

1. **新部署默认安装 Plus**：镜像切换为 `seakee/cpa-manager-plus`，容器名使用 `cpa-manager-plus`，继续使用 `18317` 端口。
2. **旧部署提供一键原地迁移**：识别现有 `cpa-manager`、安装目录和数据挂载，停旧 Manager 后复用原 `cpa-manager-data`，保留历史统计、模型价格、API 密钥别名和 CPA 连接配置。
3. **CPA API 尽量不停机**：迁移只停止旧 Manager，CPA 主服务继续处理请求；面板和统计服务允许短暂停机。
4. **迁移必须可预检、可验证、可回滚**：任何写操作前完成兼容性检查和一致性备份，验证失败时恢复旧 Compose 与迁移前数据副本。
5. **旧命令保持兼容**：已有 `install`、`upgrade`、`backup`、`status` 等入口不删除，只调整默认实现并增加 `migrate`、`preflight`、`rollback` 等能力。

这里的“无缝迁移”定义为：**外部访问端口不变、CPA API 不停机、历史数据不丢失、用户不需要手工搬运数据库，并且迁移失败可恢复**。由于 SQLite 在迁移期间不能继续由旧服务写入，不承诺 Manager Server 零停机。

## 2. 当前项目现状

当前仓库只有 `README.md` 和单文件脚本 `cpa-cpam-manager.sh`，部署模型为：

```text
CLIProxyAPI (cli-proxy-api, :8317)
        │
        └── CPA-Manager (cpa-manager, :18317)
              └── ./cpa-manager-data:/data
```

### 2.1 已具备的迁移基础

- 旧 Manager 使用宿主机目录 `./cpa-manager-data:/data`，无需转换 Docker volume，Plus 可以直接复用该目录。
- `upgrade` 已在拉取镜像前备份 Compose、CPA 配置、认证目录和 Manager 数据。
- 脚本已能检测安装目录、容器端口和 `.secrets.txt`。
- 默认 CPA 配置已启用 `remote-management.allow-remote` 和 `usage-statistics-enabled`，符合 Plus 的基本接入要求。
- Manager 对外端口已经是 `18317`，迁移后可以保持 URL 不变。

### 2.2 当前阻碍无缝迁移的问题

| 问题 | 当前行为 | 需要改进 |
| --- | --- | --- |
| 镜像与容器名 | 固定使用 `seakee/cpa-manager` / `cpa-manager` | 默认改为 Plus，并同时识别新旧容器 |
| 安装流程 | 可删除 CPA 和 Manager 容器并覆盖 `config.yaml` | 迁移模式只替换 Manager，不重建 CPA、不覆盖 CPA 配置 |
| 数据一致性 | 备份时 Manager 可能仍在写 SQLite | 先停旧 Manager，再备份完整 `usage.sqlite*` |
| 新数据密钥 | 未处理 `/data/data.key` | 首次启动后校验并纳入所有备份 |
| 登录凭证 | 只保存 CPA `MGT_KEY` | 新增独立的 `CPAMP_ADMIN_KEY`，不能混用两种密钥 |
| 健康检查 | 只检查 `/management.html` | 增加 `/health`、`/usage-service/info` 和鉴权 `/status` |
| 回滚 | 只有备份，没有自动恢复流程 | 保存迁移清单、旧 Compose、镜像信息和数据快照 |
| 版本管理 | 全部使用 `latest` | 支持镜像 tag 配置，迁移时记录实际 image ID |
| 非交互使用 | 默认回答可能直接执行 | 迁移命令要求显式确认，并支持 `--dry-run` / 环境变量 |

## 3. Plus 带来的关键变化

### 3.1 运行与数据契约

- 镜像：`seakee/cpa-manager` → `seakee/cpa-manager-plus`。
- 容器：建议从 `cpa-manager` → `cpa-manager-plus`。
- 管理页面仍为 `http://<host>:18317/management.html`。
- 数据库仍可使用 `/data/usage.sqlite`，旧数据目录可直接挂载。
- 首次启动会在 `/data/data.key` 创建加密密钥，用于解密 SQLite 中保存的 CPA Management Key。
- 旧 `settings.setup` 会迁移到 `settings.manager_config_v1`，同时保留兼容数据。
- `/usage-service/*` 兼容端点仍保留，但完整能力应从 Plus 的 Manager Server 页面访问。

### 3.2 凭证模型

迁移后存在两类不同密钥：

| 密钥 | 用途 | 建议保存位置 |
| --- | --- | --- |
| `MGT_KEY` | CPA Management API | 现有 `.secrets.txt`，后续可迁入 `secrets/` |
| `CPAMP_ADMIN_KEY`（`cpamp_...`） | Plus Manager Server 登录与管理 API | `.secrets.txt` 或独立只读 secret 文件 |

脚本应在安装或迁移前显式生成 `CPAMP_ADMIN_KEY`，避免依赖“只在首次启动日志输出一次”的自动密钥。文件权限应保持 `0600`，日志和普通状态输出默认不回显完整密钥。

### 3.3 版本前提

- 官方迁移页建议 CPA `v7.1.0+`，HTTP 用量队列最低需要 `v6.10.8+`。
- 官方 Docker 部署页进一步推荐 CPA `v7.1.39+`。
- 项目应以 `v7.1.39+` 作为推荐线，以 `v6.10.8+` 作为阻断性最低线；无法识别版本时必须提示风险，不应静默判定兼容。

## 4. 目标部署模型

### 4.1 新部署

```text
CLIProxyAPI (cli-proxy-api, :8317)
        │  Management API + Usage Queue
        ▼
CPA Manager Plus (cpa-manager-plus, :18317)
        └── ./cpa-manager-data:/data
              ├── usage.sqlite
              ├── usage.sqlite-wal
              ├── usage.sqlite-shm
              └── data.key
```

新部署继续沿用现有安装目录 `/opt/cliproxy-cpam` 和数据目录名 `cpa-manager-data`。不为了名称整齐重命名数据目录，因为保持路径不变能降低迁移、备份和用户认知成本。

### 4.2 旧部署迁移

迁移过程仅替换 Manager 服务：

```text
发现旧安装 → 预检 → 停旧 Manager → 一致性备份 → 生成 Plus 配置
    → 启动 Plus → 自动验证 → 成功固化 / 失败自动回滚
```

CPA 容器原则上不停止、不删除、不重建。若预检发现 CPA 版本过低，应先退出并提示用户单独升级 CPA，不在同一次 Manager 数据迁移中叠加两个高风险动作。

## 5. 无缝迁移功能设计

### 5.1 新增命令

| 命令 | 作用 |
| --- | --- |
| `preflight` | 只读检测安装类型、版本、容器、端口、挂载、数据和磁盘空间 |
| `migrate` | 从旧 CPA-Manager 原地迁移到 Plus |
| `migrate --dry-run` | 输出迁移计划，不停止容器、不写文件 |
| `rollback` | 使用最近一次有效迁移快照恢复旧 Manager |
| `doctor` | 对 CPA、Plus、采集器、数据目录和密钥文件做综合诊断 |

交互菜单中增加“一键迁移到 CPA Manager Plus”，但当检测到已经运行 Plus 时改为显示“无需迁移”。

### 5.2 安装类型识别

脚本应综合判断，而不是只看固定容器名：

1. 检测 `cpa-manager` 和 `cpa-manager-plus` 容器。
2. 读取 Compose label 的工作目录。
3. 检查容器实际镜像名与 image ID。
4. 解析 `/data` 的宿主机 bind mount 或 Docker named volume。
5. 检查 `usage.sqlite`、WAL、SHM 和 `data.key`。
6. 判断状态为 `legacy`、`plus`、`mixed`、`not-installed` 或 `unknown`。

`mixed` 和 `unknown` 状态默认阻断自动迁移，输出人工处理建议，避免两个 Manager 同时消费同一个 CPA 用量队列。

### 5.3 预检清单

迁移前必须通过以下检查：

- Docker 和 Compose 可用，旧 Manager 的安装目录、Compose 文件和 `/data` 挂载可确定。
- 旧 Manager 容器存在且数据目录可读写。
- CPA 容器运行正常，`/v1/models` 可用。
- 尽可能取得 CPA 版本，并按最低线与推荐线给出结论。
- `remote-management.allow-remote: true` 与 `usage-statistics-enabled: true` 已启用。
- `18317` 端口未被无关进程占用。
- 备份目标磁盘空间充足，建议至少为 Manager 数据目录大小的两倍。
- 没有另一个 Manager Server 正在消费同一 CPA 实例。
- 能生成或读取 `CPAMP_ADMIN_KEY`，且密钥文件权限可设为 `0600`。

预检输出结构化摘要，并将关键检测结果写入迁移清单，便于故障排查和回滚。

### 5.4 一致性备份

备份顺序必须固定：

1. 记录当前容器、镜像、端口、挂载和 Compose 状态。
2. 只停止旧 `cpa-manager`，等待其完全退出。
3. 复制整个 `cpa-manager-data` 目录，而不是只复制 `usage.sqlite`。
4. 备份 `docker-compose.yml`、`.secrets.txt` 和脚本生成的迁移清单。
5. 生成归档校验值并执行 `tar -tzf` 可读性验证。
6. 校验失败立即重新启动旧 Manager，并终止迁移。

建议目录结构：

```text
backups/
└── migration-YYYY-MM-DD-HHMMSS/
    ├── manifest.env
    ├── docker-compose.yml.before
    ├── secrets.before
    ├── manager-data.tar.gz
    └── SHA256SUMS
```

迁移完成后的第一次备份必须包含新生成的 `data.key`。迁移前备份与迁移后备份都要保留，不能用后者覆盖前者。

### 5.5 Compose 变更

Manager 服务调整为：

- service/container：`cpa-manager-plus`。
- image：`seakee/cpa-manager-plus:${CPAMP_IMAGE_TAG:-latest}`。
- 保持宿主机端口和 `./cpa-manager-data:/data` 不变。
- 显式设置 `USAGE_DB_PATH=/data/usage.sqlite`。
- 显式设置 `CPA_MANAGER_DATA_KEY_PATH=/data/data.key`。
- 通过环境变量或 secret 文件提供 `CPA_MANAGER_ADMIN_KEY`。
- 保持 `USAGE_COLLECTOR_MODE=auto` 等现有采集参数。
- 增加访问 `/health` 的容器 healthcheck。

Compose 文件应先写入临时文件、执行 `docker compose config` 校验，再原子替换正式文件。不要在迁移流程中重写 `config.yaml`。

### 5.6 启动后自动验证

脚本应按顺序验证：

1. `cpa-manager-plus` 容器处于运行或 healthy 状态。
2. `GET /health` 成功。
3. `GET /usage-service/info` 成功，确认兼容端点可用。
4. 使用 `CPAMP_ADMIN_KEY` 请求 `GET /status`。
5. `/status` 中 `configured` 为真，`collector.lastError` 为空或可接受。
6. `lastConsumedAt`、`lastInsertedAt`、`eventCount` 等字段存在；无新流量时不强制时间必须变化。
7. `/data/data.key` 存在、非空且权限合理。
8. SQLite 文件存在，迁移前后的历史事件数量不应异常归零。
9. `management.html` 可访问，外部端口仍为迁移前端口。

自动验证通过后才标记迁移成功，并创建迁移后备份。历史数据的页面可见性仍应列为人工验收项。

### 5.7 自动回滚

以下情况触发自动回滚：

- Plus 容器启动失败或反复退出。
- `/health`、兼容端点或鉴权 `/status` 在限定重试窗口内失败。
- `data.key` 未生成。
- SQLite 无法打开、出现解密错误或关键历史数据异常为空。

回滚步骤：

1. 停止并删除 Plus 容器，但保留故障日志和现场副本。
2. 将 Plus 已修改的数据目录移到带时间戳的失败现场目录。
3. 从迁移前快照恢复旧数据目录和旧 Compose。
4. 使用迁移前记录的镜像引用启动旧 `cpa-manager`。
5. 重新执行旧 Manager 页面和数据健康检查。

不能直接让旧 Manager 继续读取已经被 Plus 修改过的数据目录。官方说明旧版本不能识别 Plus 的管理员凭证、bootstrap 状态和加密数据，因此回滚必须优先恢复迁移前快照。

## 6. 新安装默认 Plus

完成迁移能力后，`install` 应直接生成 Plus 部署，主要变化如下：

- 项目展示名称改为“CLIProxyAPI + CPA Manager Plus”。
- `CPAM_IMAGE` 默认值改为 `seakee/cpa-manager-plus:latest`，并允许通过 `CPAMP_IMAGE_TAG` 或完整镜像环境变量覆盖。
- 自动生成 `cpamp_` 前缀的独立管理员密钥。
- `.secrets.txt` 增加 `CPAMP_ADMIN_KEY` 和 `CPAMP_MANAGER`，旧 `CPA_MANAGER` 字段可暂时保留一个发布周期作为兼容别名。
- 首次 Setup 明确要求填写三项：Plus 管理员密钥、CPA URL、CPA Management Key。
- 安装后健康检查使用 Plus 的 `/health`、`/usage-service/info` 和 `/status`。
- `logs`、`status`、`start`、`stop`、`restart`、`backup`、`uninstall` 同时兼容新旧容器名。
- 新备份始终包含完整 `cpa-manager-data`，特别是 `data.key`。

不建议把本项目的安装逻辑直接替换为上游一键安装器，因为本项目还负责 CPA 配置、OAuth 提示、防火墙、统一备份和旧安装识别。可以参考上游参数，但继续维护本项目自身的生命周期控制能力。

## 7. 分阶段实施路线

### 阶段 0：冻结契约与测试样本（P0）

目标：先固定迁移输入、输出和失败边界。

- 收集三类测试样本：当前脚本的 bind mount 安装、named volume 安装、已经迁移到 Plus 的安装。
- 定义安装状态枚举、迁移清单格式和退出码。
- 明确 `.secrets.txt` 的向后兼容字段。
- 建立 Shell 静态检查和最小函数级测试框架。

完成标准：预检规则、备份内容、回滚输入和验收指标均可被测试表达。

### 阶段 1：新安装切换 Plus（P0）

目标：所有新用户默认获得 Plus，同时不破坏现有命令接口。

- 更新镜像、容器名、环境变量、healthcheck 和安装说明。
- 增加 `CPAMP_ADMIN_KEY` 的生成、保存和脱敏展示。
- 更新健康检查、日志、状态和备份逻辑。
- README 全面改为 Plus，并增加两类密钥的说明。

完成标准：全新 Debian/Ubuntu 环境可完成安装、Setup、登录、请求采集、备份和重启恢复。

### 阶段 2：只读预检与迁移计划（P0）

目标：用户可以先看清脚本将做什么。

- 实现旧/新/混合安装识别。
- 实现 CPA 版本、挂载、数据、磁盘、端口和密钥预检。
- 实现 `preflight` 与 `migrate --dry-run`。
- 输出脱敏的计划摘要和阻断原因。

完成标准：任何预检失败都不会停止容器或修改文件；常见旧部署可以准确定位数据目录。

### 阶段 3：一键迁移与自动验证（P0）

目标：实现可恢复的原地迁移主链路。

- 实现停止旧 Manager、一致性备份、Compose 原子切换和 Plus 启动。
- 实现 `/health`、`/usage-service/info`、`/status` 和数据文件检查。
- 创建迁移前后双备份及校验值。
- 迁移成功后输出人工验收清单。

完成标准：现有 `cpa-manager-data` 历史数据在 Plus 中可见，端口不变，CPA API 迁移期间持续可用。

### 阶段 4：自动回滚与恢复演练（P0）

目标：把“有备份”升级为“可验证恢复”。

- 实现自动失败回滚和手工 `rollback`。
- 模拟镜像拉取失败、Plus 启动失败、错误管理员密钥、缺失 `data.key` 和损坏 SQLite。
- 验证旧 Manager 能从迁移前快照恢复。

完成标准：每种故障均产生清晰报告，恢复后旧面板和历史数据可用。

### 阶段 5：工程化与长期维护（P1）

目标：降低单文件脚本继续扩张后的维护成本。

- 保留单文件发布产物，但在源码层按 `detect`、`backup`、`compose`、`migrate`、`health` 拆分模块，再通过构建脚本合并发布。
- 增加 ShellCheck、格式检查、Bats 测试和临时 Docker Compose 集成测试。
- 增加版本锁定、升级通道和上游兼容矩阵。
- 为迁移清单和备份设置保留策略，避免磁盘长期增长。

完成标准：核心迁移状态机具备自动测试，发布产物仍保持用户熟悉的一键运行方式。

## 8. 测试与验收矩阵

| 场景 | 预期结果 |
| --- | --- |
| 当前脚本标准安装 | 识别为 `legacy`，原地迁移成功，端口和历史数据不变 |
| 旧 Manager 使用 named volume | 正确复用原 volume，不创建空的新数据卷 |
| 已是 Plus | 识别为 `plus`，拒绝重复迁移，允许正常升级 |
| 新旧容器同时存在 | 识别为 `mixed` 并阻断，避免双消费者 |
| CPA 版本低于最低线 | 预检阻断，不停止旧 Manager |
| CPA 版本未知 | 明确警告并要求显式确认，不静默通过 |
| 迁移前 SQLite 带 WAL/SHM | 完整备份，历史数据保持一致 |
| Plus 启动失败 | 自动恢复迁移前 Compose 和数据 |
| `data.key` 缺失或被替换 | 健康检查失败并阻断升级/恢复操作 |
| `.secrets.txt` 不存在 | 不尝试从 bcrypt 反推明文，提示用户提供密钥 |
| 非默认安装目录和端口 | 自动检测并保持现有值 |
| 无交互执行 | 除非显式提供确认参数，否则不执行迁移写操作 |

发布前至少完成一次真实 Docker 环境的端到端演练，并保存以下证据：迁移前后容器状态、备份校验结果、`/status` 摘要、历史事件数、回滚演练结果。

## 9. 安全与运维要求

- 密钥文件权限固定为 `0600`，终端摘要默认脱敏。
- 迁移清单不得记录完整 API Key、CPA Management Key 或 Plus 管理员密钥。
- Compose 校验通过前不得覆盖正式文件。
- 删除或移动目录前复用并加强现有危险路径检查。
- 默认不删除迁移前备份；清理必须是独立、显式确认的操作。
- 不同时运行两个连接同一 CPA 的 Manager Server。
- `latest` 可作为默认体验，但每次迁移必须记录实际镜像 digest/image ID，确保回滚可复现。
- 后续可以把密钥从 `.secrets.txt` 逐步迁移到 Compose secrets，但不能在首个迁移版本中同时做凭证体系大改，避免扩大风险面。

## 10. 建议的首个开发迭代

首个迭代已完成以下范围：

1. 新安装默认 Plus。
2. 新增独立 `CPAMP_ADMIN_KEY`。
3. 扩展容器识别、完整数据备份和 Plus 健康检查。
4. 实现只读 `preflight`、`migrate --dry-run`、正式迁移和自动回滚。
5. 更新 README 和命令帮助。

正式迁移当前限定为本脚本生成的标准 bind mount 部署；自定义挂载和 named volume 会被安全阻断。迁移前停止旧 Manager 创建一致性备份，验证失败自动恢复迁移前快照，CPA API 容器保持运行。

## 11. 最终完成定义

当以下条件全部满足时，可认为项目已经完成从 CPA-Manager 到 CPA Manager Plus 的方向切换：

- 新部署不再创建旧 `cpa-manager`。
- 标准旧部署可以通过一个命令完成原地迁移，无需手工复制数据库。
- CPA API 在迁移期间保持服务，Manager 访问地址和端口保持不变。
- 历史统计与旧配置在 Plus 中可见。
- `CPAMP_ADMIN_KEY` 与 `MGT_KEY` 的用途清晰分离。
- 所有备份都包含 SQLite 全套文件和 `data.key`。
- 自动验证失败时可以恢复到迁移前旧 Manager 状态。
- README、帮助文本、菜单和日志统一使用 CPA Manager Plus 名称。
- 新安装、旧安装迁移、升级、备份、恢复和卸载均通过端到端验收。

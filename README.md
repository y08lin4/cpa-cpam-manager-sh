# CPA + CPA-Manager 运维脚本

这是一个可公开发布的 Bash 运维脚本项目，用于在 Debian/Ubuntu VPS 上一键安装、升级和运维 CLIProxyAPI + CPA-Manager。

部署的容器：

- `cli-proxy-api`：使用镜像 `eceasy/cli-proxy-api:latest`
- `cpa-manager`：使用镜像 `seakee/cpa-manager:latest`

默认安装目录：`/opt/cliproxy-cpam`

> 本项目不会安装错误的静态 nginx 面板 `cpa-management-center`。如果脚本检测到旧容器，会在安装/重装时提示是否删除。

## 功能列表

- 一键安装 / 重装 CPA + CPA-Manager
- 拉取最新镜像并升级
- 启动、停止、重启容器
- 查看容器状态和健康检查
- 查看日志
- 备份配置、认证数据、日志和 CPA-Manager 数据
- 查看 API_KEY、MGT_KEY 和访问地址
- 输出 Codex OAuth 登录命令提示
- 卸载，并可选择是否保留数据
- 自动检测 Docker / Docker Compose，并在确认后安装 Docker
- 自动处理 UFW 端口放行

## 一键运行

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/y08lin4/cpa-cpam-manager-sh/main/cpa-cpam-manager.sh)
```

## 本地运行

```bash
chmod +x cpa-cpam-manager.sh
./cpa-cpam-manager.sh
```

也可以直接执行命令：

```bash
bash cpa-cpam-manager.sh menu
bash cpa-cpam-manager.sh install
bash cpa-cpam-manager.sh upgrade
bash cpa-cpam-manager.sh start
bash cpa-cpam-manager.sh stop
bash cpa-cpam-manager.sh restart
bash cpa-cpam-manager.sh status
bash cpa-cpam-manager.sh logs
bash cpa-cpam-manager.sh backup
bash cpa-cpam-manager.sh keys
bash cpa-cpam-manager.sh uninstall
bash cpa-cpam-manager.sh help
```

## 带 key 安装

```bash
API_KEY='sk-cpa-xxx' MGT_KEY='mgt-cpa-xxx' bash cpa-cpam-manager.sh install
```

也支持覆盖安装目录和端口：

```bash
INSTALL_DIR='/opt/cliproxy-cpam' CPA_HOST_PORT='8317' CPAM_HOST_PORT='18317' bash cpa-cpam-manager.sh install
```

如果不提供 `API_KEY` 或 `MGT_KEY`，脚本会自动生成：

- `API_KEY`：`sk-cpa-` + 随机 48 位 hex
- `MGT_KEY`：`mgt-cpa-` + 随机 48 位 hex

密钥会保存到：

```text
/opt/cliproxy-cpam/.secrets.txt
```

请不要提交或公开这个文件。

## 默认端口

```text
CPA API: http://服务器IP:8317/v1
CPA 自带面板: http://服务器IP:8317/management.html
CPA-Manager: http://服务器IP:18317/management.html
```

CPA-Manager 首次 Setup：

```text
CPA 地址: http://cli-proxy-api:8317
Management Key: 安装时设置的 MGT_KEY
```

说明：CPA 启动后可能会把 `config.yaml` 里的 `remote-management.secret-key` 自动转为 bcrypt hash；如果 `.secrets.txt` 丢失，无法从 bcrypt hash 反推出明文 Management Key。

## 升级

```bash
bash cpa-cpam-manager.sh upgrade
```

升级前会自动备份到：

```text
/opt/cliproxy-cpam/backups/pre-upgrade-YYYY-MM-DD-HHMMSS.tar.gz
```

## 备份

```bash
bash cpa-cpam-manager.sh backup
```

备份文件会保存到：

```text
/opt/cliproxy-cpam/backups/cpa-cpam-backup-YYYY-MM-DD-HHMMSS.tar.gz
```

## 日志

```bash
bash cpa-cpam-manager.sh logs
```

可选择查看：

- `cli-proxy-api`
- `cpa-manager`
- 两个容器最近 120 行日志

## 卸载

```bash
bash cpa-cpam-manager.sh uninstall
```

卸载时脚本会询问是否保留数据：

- 保留数据：执行 `docker compose down`，不删除安装目录
- 不保留数据：执行 `docker compose down` 后删除安装目录

## Codex OAuth 登录命令提示

脚本菜单第 10 项会输出类似命令：

```bash
cd /opt/cliproxy-cpam
docker compose exec cli-proxy-api /CLIProxyAPI/CLIProxyAPI -no-browser --codex-login
```

按提示在你本地电脑执行它给出的 `ssh -L` 隧道命令，然后用本地浏览器打开授权链接。

## 安全提醒

```text
不要提交 .secrets.txt
不要公开 API_KEY / MGT_KEY
不要把 key 发到 issue、TG、截图里
云厂商安全组需要放行 8317/18317
```

默认 `.gitignore` 已排除：

- `.secrets.txt`
- `auths/`
- `logs/`
- `cpa-manager-data/`
- `backups/`

## 防火墙说明

如果检测到 `ufw` 已启用，脚本会自动放行：

```text
8317/tcp
18317/tcp
8085/tcp
1455/tcp
54545/tcp
51121/tcp
11451/tcp
```

如果 `ufw` 未启用，脚本不会默认启用，避免锁 SSH；只有在你确认后才会放行 SSH、CPA、CPA-Manager 相关端口并启用 UFW。

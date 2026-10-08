# 数据备份与恢复

RST AI Copilot for Prometheus 自己的持久化数据全部在安装主机上：网关状态卷、PostgreSQL 数据卷、Caddy 证书卷和
安装目录里的几个文件。`scripts/backup.sh` 一次备齐。指标和告警本身在客户的 Prometheus / Alertmanager 里，
由客户原有的方式备份，不在本文范围。

| 数据 | 在哪 | 备份方式 |
|---|---|---|
| 网关配置 / 大模型配置 / License 激活记录 / 加密密钥 | `gateway_state` 卷（`/app/state`） | `scripts/backup.sh` |
| `.env` + 主机指纹两半（`state/machine-id`、`state/server_guid`） | 安装目录（默认 `/opt/rst-ai-copilot-for-prometheus`） | `scripts/backup.sh`（一并） |
| 账号与角色、审计事件、会话、分析记录、报表历史、通知配置与投递记录、知识库向量 | `pg_data` 卷（PostgreSQL + pgvector） | `scripts/backup.sh`（`pg_dump`，一并） |
| Caddy 内置 CA 根证书 + 站点证书 | `caddy_data` 卷（`/data`） | `scripts/backup.sh`（一并） |
| 反馈失败用例 | 容器内 `/app/eval/failed_cases.yaml` | `scripts/backup.sh`（一并） |

用客户自己的 PostgreSQL（`RST_DB_URL` 指向外部库）时，数据库由客户 DBA 按其策略备份，脚本会跳过这一项。

---

## 1. 备份（脚本）

```bash
bash scripts/backup.sh [备份目录]      # 默认 ./backups
```

产物（脚本自动保留 30 天、清理更早的）：

| 文件 | 内容 | 丢了会怎样 |
|---|---|---|
| `gateway-state-<时间戳>.tar.gz` | `/app/state`：设置、大模型配置、License 激活记录、`.rst_secret_key` | 配置和激活记录没了；通知渠道的 webhook 和 SMTP 口令解不开 |
| `host-files-<时间戳>.tar.gz` | `.env`、`state/machine-id`、`state/server_guid` | **主机指纹变了，License 要重新激活**；`.env` 里的大模型、数据源凭据和内部密钥要重填 |
| `postgres-<时间戳>.dump` | `pg_dump -Fc` 整库 | 账号只剩 `.env` 里的首个管理员；审计、报表历史、投递记录、知识库全部丢失 |
| `caddy-data-<时间戳>.tar.gz` | Caddy `/data`：内置 CA 根证书和站点证书 | Caddy 生成新的根证书，运维浏览器要重新信任 |
| `failed_cases-<时间戳>.yaml` | 反馈失败用例（有才生成） | — |

脚本按自己所在位置找安装目录里的 `.env` 和 `state/`，所以用安装目录里的那份 `scripts/backup.sh`。容器名可用
环境变量改：`RST_GATEWAY_CONTAINER`、`RST_PG_CONTAINER`、`RST_CADDY_CONTAINER`。SSO 部署设
`RST_GATEWAY_CONTAINER=rst-ai-copilot-for-prometheus-sso-gateway`、`RST_PG_CONTAINER=rst-ai-copilot-for-prometheus-sso-postgres`、
`RST_CADDY_CONTAINER=rst-ai-copilot-for-prometheus-sso-caddy`。

> **这些文件等价于明文凭据。** `.env` 里有大模型 key、数据源口令和内部密钥；`/app/state` 里同时有加密的设置和
> 解密它们的 `.rst_secret_key`；数据库导出里有账号口令 hash 和全部审计事件。备份目录按 `chmod 700` 存，
> 离机保存要再加一层加密。
>
> 反过来也成立：**恢复必须带上 `.rst_secret_key`**，否则通知渠道的 webhook、签名密钥和 SMTP 口令解不开，
> 界面上会显示成「需要重新填写」。

**建议挂 cron**（每日 02:00）：

```cron
0 2 * * * cd /opt/rst-ai-copilot-for-prometheus && bash scripts/backup.sh /backup/rst-copilot >> /backup/rst-copilot/backup.out 2>&1
```

---

## 2. 恢复

按文件名识别，一次可给多个：

```bash
bash scripts/restore.sh /backup/rst-copilot/host-files-XXXX.tar.gz \
                        /backup/rst-copilot/gateway-state-XXXX.tar.gz \
                        /backup/rst-copilot/postgres-XXXX.dump \
                        /backup/rst-copilot/caddy-data-XXXX.tar.gz \
                        /backup/rst-copilot/failed_cases-XXXX.yaml
docker compose -f docker-compose.prod.yml up -d --force-recreate gateway caddy
```

- 用 `up -d --force-recreate` 而不是 `restart`：`.env` 和挂进容器的 `state/` 文件只在建容器时读。
- 恢复 `host-files` 前，现有 `.env` 会另存为 `.env.<时间>.pre-restore.bak`。
- 数据库用 `pg_restore --clean --if-exists` 覆盖现有数据。恢复的镜像版本应**不低于**备份时的版本：
  新版本启动时会自动补上缺的迁移，旧版本读不了新表结构。

**换机恢复**（指纹跟着 `state/` 走，License 不用重新激活）：在新主机把**同版本**交付包解压到
`/opt/rst-ai-copilot-for-prometheus` → `bash scripts/restore.sh host-files-XXXX.tar.gz` → `./deploy.sh` 选
「保留现有 .env」（会起好 PostgreSQL 和网关）→
`bash scripts/restore.sh gateway-state-XXXX.tar.gz postgres-XXXX.dump caddy-data-XXXX.tar.gz` → 按上面重建容器。
旧主机上的同一份 `state/` 不要再同时运行。

---

## 3. 恢复演练

备份只有验证过能恢复才算数。**上线前至少演练一次**：在一台测试机上 `restore.sh`，确认网关起来后
License 为「有效」、账号能登录、报表历史和通知投递记录都在。

## 4. 留存周期

| 数据 | 建议留存 |
|---|---|
| 网关状态、数据库导出 | 30 天（脚本默认） |
| 审计事件 | 按客户的合规要求，通常 180 天起：把数据库导出另行归档 |

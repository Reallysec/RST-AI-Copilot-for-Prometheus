# 部署文档 — RST AI Copilot for Prometheus

面向实施 / 运维。本文是**权威部署指南**；备份细节见 [`BACKUP.md`](BACKUP.md)，许可条款见
[`EULA.md`](EULA.md)。English: [`DEPLOYMENT.en.md`](DEPLOYMENT.en.md)。

> 0.1.0 是预览版，用于演示和试点。

---

## 1. 概览

- **定位**：网络运维 AI 副驾。设备是交换机、路由器、防火墙，指标由 snmp_exporter（SNMP）和
  blackbox_exporter（ICMP / TCP / HTTP 探测）采集进 Prometheus。
- **形态**：仅 Docker。网关 + PostgreSQL（pgvector）+ Caddy 三个容器；许可门控和付费引擎已 Cython 编译进镜像。
- **不带 Prometheus**：连接客户**已有的 Prometheus、Alertmanager**，Grafana 可选（只用于跳转链接）。
  没有现网环境时，用网络实验室叠加演示（§9）。
- **版本**：同一个交付包。不激活即免费社区版（1 个用户）；专业版 / 企业版在界面上激活（§10）。
- **默认单副本、网关自带登录**；多用户和 SSO 见 §13。

```
运维浏览器 ──HTTPS(443)──▶ Caddy 反代 ──HTTP(内网)──▶ AI 网关(FastAPI)
                          TLS                          │
                                                       ├─▶ PostgreSQL + pgvector(同一 compose 内)
                                                       ├─▶ 客户 Prometheus:9090 / Alertmanager:9093
                                                       ├─▶ 大模型端点(火山方舟 / 自建模型):443
                                                       ├─▶ 通知渠道(飞书 / 钉钉 / 企业微信 / 邮件 / Webhook)
                                                       └─▶ license.reallysec.com:443(激活 / 心跳 / 更新)
```

容器：`rst-prometheus-ai-copilot-gateway`、`rst-prometheus-ai-copilot-postgres`、`rst-prometheus-ai-copilot-caddy`。

---

## 2. 系统要求与支持矩阵

| 项 | 要求 |
|---|---|
| 操作系统 | x86_64 Linux：Ubuntu 20.04 / 22.04 / 24.04、RHEL / CentOS 8+、麒麟、统信等能跑 Docker 24+ 的发行版 |
| 运行时 | Docker Engine **24+** 与 Docker Compose **v2**（`docker compose` 插件），bash 4+。`deploy.sh` 预检这两项 |
| CPU / 内存 | 2 vCPU / 4 GB 起（网关容器上限默认 2 CPU / 2 GB，见 `RST_GATEWAY_CPUS` / `RST_GATEWAY_MEM`）；叠加网络实验室演示时 4 vCPU / 8 GB 起 |
| 磁盘 | 20 GB+（镜像、PostgreSQL 数据、状态） |
| Prometheus | 2.43 及以上，网关主机网络可达；HTTP API（`/api/v1/*`）可用，支持 Basic / Bearer 认证与私有 CA |
| Alertmanager | 0.25 及以上，API v2 可用（读告警、建 / 撤静默） |
| Grafana | 可选，9 及以上；只需运维人员的浏览器能打开 |
| 采集 | snmp_exporter、blackbox_exporter（厂商识别靠 `sysObjectID`，见 §8） |
| 大模型 | `LLM_API_KEY` / `LLM_BASE_URL` / `LLM_MODEL`：火山方舟、任意 OpenAI 兼容端点、自建 vLLM / Ollama |
| 访问名 | **域名或 IP** 均可（见 §3）；证书默认自签名 |
| License | 社区版不需要；专业版 / 企业版在界面上激活（§10） |

---

## 3. 防火墙：端口与域名

**入站**（放通到网关主机）：

| 端口 | 协议 | 来源 | 用途 |
|---|---|---|---|
| 443 | TCP | 运维网段 | `https://<域名>/v2/` —— 唯一入口 |
| 80 | TCP | 运维网段 | HTTP→HTTPS 跳转（可选） |

> 网关 8000、PostgreSQL 5432 **不对外**，只在 compose 内部网络。云主机记得在**安全组**同步放通 443。

**出站**（网关主机需能访问）：

| 目标 | 端口 | 用途 | 必需 |
|---|---|---|---|
| 客户 Prometheus | 9090（或反代端口） | 指标查询、PromQL 校验、规则状态 | ✅ |
| 客户 Alertmanager | 9093（或反代端口） | 读告警、建 / 撤静默 | ✅ |
| 大模型端点（如 `ark.cn-beijing.volces.com`） | 443 | 推理 + 向量化 | ✅ |
| `license.reallysec.com` | 443 | 激活 + 心跳（有许可时；离线许可不需要） | 有许可时 |
| 通知渠道（`open.feishu.cn`、`oapi.dingtalk.com`、`qyapi.weixin.qq.com`、SMTP、自定义 Webhook） | 443 / 25 / 465 / 587 | 投递调查结论和日报周报 | 用通知时 |
| `github.com`、`release-assets.githubusercontent.com` | 443 | 在线更新：每天检查新版本、下载交付包 | 用在线更新时 |

Grafana 不在出站表里：网关只拼 Grafana 的浏览器链接，不调它的 API。

**站点地址（域名或 IP）**：`CADDY_SITE_ADDRESS` 填运维人员访问用的域名或 IP。用**裸 IP**（如
`https://10.250.1.82/v2/`）也能用：浏览器直连 IP 不发 SNI，Caddy 靠 `default_sni` 兜底（`CADDY_DEFAULT_SNI`
缺省回退到站点地址）。deploy.sh 会自动写好；手工编辑时若 `CADDY_SITE_ADDRESS` 填了多个空格分隔的地址，
须把 `CADDY_DEFAULT_SNI` 设为其中一个。

**证书**：由 `.env` 的 `CADDY_TLS` 决定，升级换包不会覆盖它：

| `CADDY_TLS` | 效果 |
|---|---|
| `internal`（默认） | Caddy 内置 CA 签发的**自签名证书**，IP 和域名都适用；把根证书分发给运维电脑信任即可（`docker exec rst-prometheus-ai-copilot-caddy cat /data/caddy/pki/authorities/local/root.crt`） |
| `/etc/caddy/certs/cert.pem /etc/caddy/certs/key.pem` | 客户自己的证书：把 `cert.pem`、`key.pem` 放进安装目录的 `./certs` |
| `you@example.com` | Let's Encrypt 公网证书：需要公网 DNS 域名，且 80/443 能从公网访问 |

改完执行 `docker compose -f docker-compose.prod.yml up -d caddy` 生效。

---

## 4. 获取交付包

一体包 `RST-Prometheus-AI-Copilot-<版本>.tar.gz` = 镜像 tar（网关、Caddy、`pgvector/pgvector:pg16`）+ 全部
部署文件（compose、Caddyfile、`.env.example`、`deploy.sh`、`deploy/` 更新脚本、`scripts/` 备份脚本、`docs/`）。
所有版本是同一个包，附 `.sha256` 校验文件：

```bash
sha256sum -c RST-Prometheus-AI-Copilot-<版本>.tar.gz.sha256
```

离线主机：在有网的机器上下载、校验，再把包和 `.sha256` 拷过去。包里已含全部镜像，部署时不需要访问镜像仓库。

---

## 5. 安装 Docker（目标主机）

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER          # 退出重登生效
docker version && docker compose version
```

离线主机按发行版用离线安装包装 Docker Engine 24+ 和 Compose 插件。

---

## 6. 一键部署

把交付包解压到固定目录（推荐 `/opt/rst-prometheus-ai-copilot`，以后升级解压到同一目录）后跑 `deploy.sh`：

```bash
sudo mkdir -p /opt/rst-prometheus-ai-copilot
sudo tar xzf RST-Prometheus-AI-Copilot-<版本>.tar.gz -C /opt/rst-prometheus-ai-copilot --strip-components=1
cd /opt/rst-prometheus-ai-copilot && sudo ./deploy.sh
```

`deploy.sh` 交互引导（提示中英双语）：

1. **预检** Docker 24+ / Compose v2，生成 `state/machine-id` 和 `state/server_guid`（许可硬件指纹的两半，**永不重建**）。
2. **自动 `docker load`** 包内镜像 tar。
3. 选**认证方式**：1 = 网关自带 `/v2` 登录；2 = SSO（OIDC，**需企业版许可**）。
4. 填**大模型**地址 / key / 模型 id 和**时区**（默认 `+08:00`，模型理解「今天」「昨天」靠它）。
5. 填**数据源**，每项都可留空、装完在「设置 → 数据源连接」里补：
   - Prometheus URL，认证选「无 / Basic（用户名 + 口令）/ Bearer token」；
   - Alertmanager URL，认证同上；
   - Grafana URL（浏览器能打开的地址）和 Prometheus 数据源 UID（默认 `prometheus`）。Grafana 没有认证项：
     网关只生成跳转链接，跳过去用的是运维自己的 Grafana 登录态。
6. 填**访问域名或 IP**；网关自带登录时**设定 `admin` 的口令**（至少 8 位，写成 `RST_ADMIN_PASSWORD_HASH`）；
   SSO 时填 OIDC issuer / client id / client secret。
7. 自动生成内部密钥（网关共享密钥、管理 token、PostgreSQL 口令）→ 确认 → 写 `.env`（权限 600）。
8. `docker compose -f docker-compose.prod.yml up -d`，等全部 healthy，打印访问地址和后续步骤。

重跑 `deploy.sh` 选「保留现有 .env」只加载新镜像并重建容器，不再问配置；选覆盖时旧 `.env` 先备份成
`.env.<时间>.bak`，PostgreSQL 口令沿用旧值（数据卷是用旧口令初始化的）。

**手动备选**（不走交互）：`cp .env.example .env` 填必填项（见 §18）→
`docker load < RST-Prometheus-AI-Copilot-images-<版本>.tar` → `docker compose -f docker-compose.prod.yml up -d`。

**用客户自己的 PostgreSQL**：需要 PostgreSQL 16 并装好 pgvector 扩展。把 `.env` 的 `RST_DB_URL` 指过去，
然后只起 `gateway caddy`：`docker compose -f docker-compose.prod.yml up -d --no-deps gateway caddy`。
网关启动时自动建表（迁移脚本只在本产品自己的表上执行）。

---

## 7. 冒烟验证

```bash
curl -k https://copilot.corp.local/healthz     # → {"status":"ok"}
curl -k https://copilot.corp.local/readyz      # 看 db / prometheus
```

- `/healthz` = 进程存活。
- `/readyz` 要求数据库可达且 Prometheus 可连；`prometheus_configured: false` 表示还没配数据源（预期，去设置页填）。
- 登录后在「设置 → 数据源连接」逐个点「测试」，Prometheus 和 Alertmanager 应返回版本号。

---

## 8. 数据源准备

**Prometheus**

- 网关用只读的 HTTP API：`/api/v1/query`、`query_range`、`series`、`labels`、`metadata`、`targets`、`rules`、
  `status/*`。前面有反向代理做认证时，给网关一个只读账号（Basic 或 Bearer）。
- 私有 CA：CA 放进安装目录 `./certs`，`.env` 设 `RST_PROMETHEUS_CA_CERT=/certs/ca.pem`；不要关校验。
- **标签约定**（网络内容包按此编写）：snmp 采集任务的 `job` 以 `snmp` 开头；blackbox 探测与 snmp 采集对同一台
  设备用同一个 `instance`；`site` / `role` / `vendor` 作为 target 标签可选，有就会被带进记录规则和告警。
- **厂商识别**：按 `sysObjectID` 的企业号前缀。华为、H3C、Cisco、锐捷、Juniper、Fortinet、深信服等走私有 MIB；
  识别不出的走 IF-MIB、ENTITY-MIB、ENTITY-SENSOR-MIB、HOST-RESOURCES-MIB 兜底。
- **设备台账指标（必需）**：网络规则包依赖台账导出的三个 `rst_*` 指标（接口告警策略、防火墙会话上限、
  HA 标记），由 Copilot 在 `/metrics/inventory` 暴露。客户的 Prometheus 通常不在本产品的 compose 里，
  需要在它的 `prometheus.yml` 加一个抓取任务（地址换成 Copilot 的访问地址；设了 `RST_METRICS_TOKEN`
  时带上 `authorization`）：

  ```yaml
  - job_name: rst-inventory
    honor_labels: true
    metrics_path: /metrics/inventory
    scrape_interval: 60s
    scheme: https
    # authorization:
    #   credentials: <RST_METRICS_TOKEN>
    static_configs:
      - targets: ["copilot.example.com:443"]
  ```

  不加的话，接口 down 只按默认口径（`ifAlias` 非空）告警、防火墙不报「接近会话上限」、HA 异常不报。
  开发栈（`deploy/dev/prometheus`）和实验室演示（`deploy/lab-demo`）的 Prometheus 已经带了这一段。
- **告警规则写回**（可选）：Copilot 生成的规则经审批后写进它自己的规则文件，Prometheus 需要加载这个目录并开启
  `--web.enable-lifecycle` 以便热加载。

**snmp_exporter 配置**

网络内容包的指标名、标签按 `deploy/snmp_exporter/snmp.yml` 编写（官方 generator 基于公开 MIB 生成，模块名与
`vendors.yaml` 一致）。客户的 snmp_exporter 请直接用这份配置（另建 `auths.yml` 放团体字/SNMPv3），按设备类型选模块；
需要加厂商 MIB 时在客户环境重新生成。深信服 AF 没有公开 MIB，`sangfor.snmp.yml` 是未核实的占位模块，需从 AF
「系统设置 → 下载 MIB 库」导出 MIB 后重新生成。步骤见 `deploy/snmp_exporter/README.md`，核对记录见
`docs/MIB-VERIFICATION.md`。

**Alertmanager**

- 网关读 `/api/v2/alerts`、`/api/v2/status`，读写 `/api/v2/silences`（建静默、撤静默，全部写审计）。
- **告警路由不变**：分组、抑制、发给值班的通知仍由 Alertmanager 自己的 `route` / `receivers` 负责。
  Copilot 的通知模块只投递 AI 产出（§12），不会重复发告警。

**Grafana**（可选）：`GRAFANA_URL` 填浏览器能打开的地址，`GRAFANA_DATASOURCE_UID` 填 Grafana 里 Prometheus 数据源
的 UID，告警和查询结果上就会出现「在 Grafana 中打开」。

---

## 9. 网络实验室演示（叠加到部署栈）

没有现网设备的演示、试点和培训环境，用 `docker-compose.lab-demo.yml` 把仓库里的网络实验室（`lab/`）叠加到部署栈上：
30 台模拟设备（13 个厂商 + 1 台通用 MIB 设备，snmpsim 提供 SNMP），snmp_exporter、blackbox_exporter 采集，
外加一套 Prometheus（加载 `lab/prometheus/scrape-*.yml` 和产品自带的网络规则包）、Alertmanager（只收不发）
和 Grafana，并把网关的数据源指向它们。

```bash
# 在安装目录（或仓库根目录），deploy.sh 写好 .env 之后（数据源问题留空即可，叠加文件会填）：
docker compose -f docker-compose.prod.yml -f docker-compose.lab-demo.yml up -d --build
```

- `--build` 只在第一次需要：snmpsim 镜像从 `lab/sim` 构建。需要交付包之外的 `lab/` 目录和
  `app/backend/content/network/rule_pack/`，所以演示一般直接在仓库检出目录里跑。
- 访问：Copilot `https://<CADDY_SITE_ADDRESS>/v2/`；Grafana `http://<主机>:23000/`（匿名只读，端口可用
  `LAB_DEMO_GRAFANA_PORT` 改，浏览器跳转地址用 `LAB_DEMO_GRAFANA_URL` 改）。
- `lab/` 自带的 `lab-prometheus`、`lab-alertmanager` 也会起来（宿主机端口 19090 / 19093，可用 `LAB_PROMETHEUS_PORT` /
  `LAB_ALERTMANAGER_PORT` 改），网关不用它们。
- 故障场景（链路 down、带宽打满、错包等）：`sh lab/scenario.sh on <场景>`，用完 `off <场景>`，见 `lab/README.md`。
- 停止：`docker compose -f docker-compose.prod.yml -f docker-compose.lab-demo.yml down`（加 `-v` 连数据一起删）。

开发机上用开发栈也可以：`LAB_DIR=./lab docker compose -f docker-compose.yml -f lab/docker-compose.lab.yml up -d --build`，
开发栈的 Prometheus 已经加载 lab 的采集配置。

---

## 10. License 激活（绑本机）

**社区版不需要激活**：装好即可用（1 个用户）。专业版 / 企业版 / 试用按下面做。

以 **admin** 登录 `https://<地址>/v2/` → 侧栏 **产品激活**（`/v2/license`）。只有管理员能激活：

**在线激活**（默认，需出站 `license.reallysec.com:443`）：

1. 「在线激活」页签里粘贴 license key。
2. 点 **激活** → 状态变为「有效」。许可自动绑定本机主机指纹。

**离线激活**（企业版，离线主机全程不联网）：

1. 切到「离线激活」页签，复制 **主机指纹**。
2. 把指纹交给厂商，拿回绑定该指纹的离线 license 文件（`.lic`）。
3. 上传该文件 → **激活**，本地校验后解锁。

> ⚠️ **永不重建 `state/machine-id` / `state/server_guid`** —— 换文件 = 换硬件，license 要重激活。

---

## 11. 访问与口令

```
https://copilot.corp.local/v2/
```

用 `admin` + **部署时设定的口令**登录。`.env` 里没有 `RST_ADMIN_PASSWORD_HASH` 时，网关拒绝一切经浏览器（Caddy）
进来的登录，并在每次启动时告警。

**忘记 / 更换管理员口令**（单账号部署），在安装目录：

```bash
docker exec rst-prometheus-ai-copilot-gateway python -m backend.session_auth '<新口令>'
# 把输出写进 .env 的 RST_ADMIN_PASSWORD_HASH=，其中每个 $ 写成 $$
docker compose -f docker-compose.prod.yml up -d gateway
```

改口令会让所有已登录会话失效。多账号部署由管理员在「用户」页重置他人口令。

---

## 12. 报表与通知

- **报表**（`/v2/reports`）：网络运维日报、周报，包含告警概况、利用率 TOP 链路、错包 / 丢包、设备可用率、
  容量风险和 AI 调查结论摘要。可随时生成，也可定时生成；历史归档在 PostgreSQL，可导出。
  容量风险一节：社区版只列当前利用率排行；专业版按报表周期（日报 1 天、周报 7 天、月报 30 天）拟合趋势并外推，
  历史数据不足拟合窗口的对象标「数据不足」，不出预测。
- 通知目标的「订阅 AI 调查结论」与「接收升级推送」是两个独立开关：前者收调查结论，后者收分诊里升级的告警聚类。
- **通知**（`/v2/notify`）：渠道为飞书、钉钉、企业微信、邮件、Webhook。**只投递 AI 产出**：调查结论和日报周报。
  它不是告警路由，不转发 Alertmanager 的告警；告警通知仍由 Alertmanager 负责，避免同一条告警发两遍。
  投递走 PostgreSQL 里的出站队列，失败按退避重试，超过次数进死信，修好渠道后可在页面上重投。
- 渠道的 webhook 地址和签名密钥、SMTP 口令加密保存（密钥在 `gateway_state` 卷的 `.rst_secret_key`），界面上不回显。

---

## 13. 多用户与 SSO

社区版只有 1 个用户（admin）。专业版和企业版许可带席位数 `max_users`，网关把**启用中**的账号数卡在这个数以内。

两条路，按客户有没有 IdP 选一条，**不要同时开**。

### 13.1 网关自己管账号

账号存在同一个 PostgreSQL 里，不需要额外配置。首次启动会把 `RST_ADMIN_USERNAME` / `RST_ADMIN_PASSWORD_HASH`
写成第一个管理员。之后管理员在「用户」页增删账号、改角色、停用，**立即生效**。

### 13.2 SSO（企业版）

**需要企业版许可**（`sso_oidc`）。`deploy.sh` 选认证方式 2，或手工改用 `docker-compose.sso.yml`
（Caddy → oauth2-proxy → 网关）。在客户 IdP 注册一个 OIDC client，回调 URI 填 `https://<地址>/oauth2/callback`，
`.env` 里设 `OIDC_ISSUER_URL`、`OIDC_CLIENT_ID`、`OIDC_CLIENT_SECRET`、`OAUTH2_PROXY_REDIRECT_URL`、
`OAUTH2_PROXY_COOKIE_SECRET`（`openssl rand -base64 32`）、`OAUTH2_PROXY_COOKIE_SECURE=true`、
`OAUTH2_PROXY_REVERSE_PROXY=true`、`OAUTH2_PROXY_SKIP_OIDC_DISCOVERY=false`（`deploy.sh` 会全部写好）。
SSO 栈同样自带 `pgvector/pgvector:pg16`，用同一套 `RST_DB_URL`。

compose 里的 `--profile bundled-idp`（Keycloak + OpenLDAP）**只是演示 / 测试夹具**，只监听 `127.0.0.1`，
启动前必须在 `.env` 设 `KEYCLOAK_ADMIN_PASSWORD`。生产不要启用。

### 13.3 三档角色

| 角色 | 能做什么 |
|---|---|
| `admin` 管理员 | 全部，含用户、许可、AI 设置 |
| `operator` 运维工程师 | 除用户、许可、AI 设置外的全部：查询、调查、部署告警规则（单人审批）、建 / 撤静默、改设置 |
| `viewer` 只读 | 只读。除登录 / 登出 / 改自己口令外，任何写请求一律 403 |

SSO 部署下角色来自 IdP 组：

```bash
RST_RBAC_ADMIN_GROUPS=netops-admins
RST_RBAC_OPERATOR_GROUPS=netops-l1,netops-l2
RST_RBAC_VIEWER_GROUPS=auditors
```

一个人在多个组里，取最高的那一档。

### 13.4 审计

数据库可用时审计**默认开启**：每个写操作（部署规则、建 / 撤静默、改设置、用户和许可变更等）和每次模型调用都写一条审计事件到
PostgreSQL，在「审计日志」页查看。确实不需要时在 `.env` 里设 `RST_AUDIT_ENABLED=false` 关闭（也接受 `0` / `no`），
然后 `docker compose up -d` 重建网关容器生效。未配置数据库时审计不写入。

**EULA 确认**：每个账号（含 SSO 用户）首次登录及 EULA 版本变更后须勾选同意，否则业务接口返回 403；同意记录
（账号、时间、版本）存在 PostgreSQL 表 `rst_eula_acceptances`，并写一条 `eula_accept` 审计事件。没有逐个用户身份时
（只用运维令牌）由管理员代表整个安装实例同意一次。

---

## 14. 升级 / 回滚

**换包升级**（离线主机也适用）：新版交付包解压到**同一个安装目录**后重跑 `deploy.sh`，选「保留现有 .env」，
它会加载新镜像并把 `GATEWAY_IMAGE_TAG` 改成新版本。`.env`、`state/` 和数据卷都保留，指纹不变，不用重新激活。
数据库表结构由网关启动时的迁移自动升级。

**在线更新**分两段（签名 + 健康门控）：

1. **网关侧**（下载暂存）：网关心跳收到新版 → License/更新页触发下载。验签 + 每个制品 sha256，fail-closed 写入
   `./release/staging`。
2. **主机侧**（安装）：
   ```bash
   ./deploy/rst-update.sh              # 载暂存镜像 → 切 GATEWAY_IMAGE_TAG → 健康探测
   ./deploy/rst-update.sh --rollback   # 回上一版
   ```
   `/healthz` 连续 3 次 200 才算成功，否则**自动回滚**。脚本会把交付包里的 compose 文件和 Caddyfile 一并换成新版
   （旧文件留作 `*.bak`，回滚时自动放回），`.env` 和 `./certs` 不动。

升级前按 §15 备份，尤其是 PostgreSQL：数据库迁移不可逆，回滚镜像不会回滚表结构。

**内容包**：每天的更新检查发现较新的签名内容包时，默认验签后自动启用。不想自动切换就在 `.env` 设
`RST_CONTENT_AUTO_APPLY=0`：新内容包只保存，管理员用 `POST /api/admin/content/rollback/<版本>` 启用（也可切回较早版本），
`GET /api/admin/content/status` 查看已保存的版本。

---

## 15. 备份

纳入备份：

- `.env` 和 `./state/`（machine-id + server_guid —— 指纹的两半，丢了 license 要重激活）
- `gateway_state` 卷（设置、模型配置、激活记录、加密密钥）
- `pg_data` 卷（PostgreSQL：账号、审计、报表历史、通知投递记录、知识库向量）
- `caddy_data` 卷（内置 CA 根证书；丢了浏览器要重新信任新证书）

`scripts/backup.sh` 一次备齐（在安装目录里运行），`scripts/restore.sh` 恢复。详见 [`BACKUP.md`](BACKUP.md)。

---

## 16. 故障排查

| 症状 | 排查 |
|---|---|
| 打不开 `/v2/` | `docker compose -f docker-compose.prod.yml logs caddy gateway`；确认入站 443、`CADDY_SITE_ADDRESS` 是实际访问的域名或 IP |
| 浏览器提示证书不安全 | 默认自签名证书（§3）：信任 Caddy 根证书或换自有证书 |
| 登录提示口令被拒（远程登录） | `.env` 缺 `RST_ADMIN_PASSWORD_HASH`，按 §11 设置 |
| HTTPS 握手失败（裸 IP） | 确认 caddy 传入了 `CADDY_DEFAULT_SNI`；`docker restart rst-prometheus-ai-copilot-caddy` 生效 |
| `/readyz` 503，`db: unreachable` | `docker compose -f docker-compose.prod.yml ps postgres`；`.env` 的 `RST_DB_URL` 口令与 `RST_DB_PASSWORD` 是否一致 |
| `/readyz` 503，`prometheus` 不是 `ok` | 网关到 Prometheus 是否通（`docker exec rst-prometheus-ai-copilot-gateway curl -s $PROMETHEUS_URL/-/ready`）；认证和 CA 是否正确 |
| 查询报错 / 空 | 设置页测试数据源；PromQL 校验失败时页面会显示 Prometheus 的原始报错；大模型 key / endpoint 是否正确 |
| 告警页为空 | Alertmanager URL 和认证；Alertmanager 自己是否有活动告警 |
| 通知发不出 | 「通知」页看投递记录里的错误；出站到渠道域名是否放通；修好后点「重投」 |
| 激活报“无法连接 license 服务器” | 出站到 `license.reallysec.com:443` 是否放通；离线主机走离线激活（§10） |
| 更新后异常 | `./deploy/rst-update.sh --rollback` 回滚 |
| license 突然失效 | 是否重建过 `state/machine-id` / `state/server_guid`？ |

---

## 17. 卸载

在安装目录（默认 `/opt/rst-prometheus-ai-copilot`）操作。先按 §15 备份，除非确定不再需要。

```bash
cd /opt/rst-prometheus-ai-copilot
# SSO 部署把文件换成 docker-compose.sso.yml

# A. 停止并删除容器，保留数据卷（以后在同目录重新 ./deploy.sh 可原样恢复）
docker compose -f docker-compose.prod.yml down

# B. 连数据卷一起删：网关状态、数据库、Caddy 证书全部丢失，不可恢复
docker compose -f docker-compose.prod.yml down -v

# 删除镜像（版本号按 docker image ls 实际所见）
docker image rm rst-prometheus-ai-copilot-gateway:<版本> caddy:2 pgvector/pgvector:pg16

# 删除安装目录（含 .env 和 state/）
cd / && sudo rm -rf /opt/rst-prometheus-ai-copilot
```

- **客户 Prometheus / Alertmanager 不受影响**：Copilot 写过的规则文件和静默由客户自行清理。
- **License**：卸载不会通知许可服务器，这台主机的指纹仍记作一个已占用的节点。换机时按 §15 恢复 `state/`
  （指纹不变，直接沿用），或联系厂商释放旧节点后在新主机重新激活。

---

## 18. 附录：`.env` 关键项

```bash
# —— 大模型（可选；不配则查询退回关键词生成，也可在「设置」里配）——
LLM_API_KEY=<key>
LLM_BASE_URL=https://ark.cn-beijing.volces.com/api/v3   # 配模型时必填，无内置默认
LLM_MODEL=<model 或 endpoint id>
RST_TIMEZONE=+08:00

# —— 数据源（可留空，之后在「设置 → 数据源连接」里填）——
PROMETHEUS_URL=http://prometheus.corp.local:9090
# PROMETHEUS_USER= / PROMETHEUS_PASSWORD=     或  PROMETHEUS_BEARER_TOKEN=
# RST_PROMETHEUS_CA_CERT=/certs/ca.pem        # 私有 CA
ALERTMANAGER_URL=http://alertmanager.corp.local:9093
# ALERTMANAGER_USER= / ALERTMANAGER_PASSWORD= 或  ALERTMANAGER_BEARER_TOKEN=
GRAFANA_URL=https://grafana.corp.local       # 浏览器能打开的地址，只用于跳转链接
GRAFANA_DATASOURCE_UID=prometheus

# —— PostgreSQL（自带的 pgvector/pgvector:pg16；口令两处一致）——
RST_DB_PASSWORD=<openssl rand -hex 32>
RST_DB_URL=postgresql://rst:<同上>@postgres:5432/rst

# —— 网关认证（必填，各 32+ 随机串）——
RST_GATEWAY_SHARED_SECRET=<openssl rand -hex 32>
RST_ADMIN_TOKEN=<openssl rand -hex 32>
RST_ADMIN_PASSWORD_HASH=<docker exec rst-prometheus-ai-copilot-gateway python -m backend.session_auth 'PWD'，$ 写成 $$>

# —— Caddy 反代（必填）——
CADDY_SITE_ADDRESS=copilot.corp.local   # 域名或 IP 均可
# CADDY_DEFAULT_SNI=                    # 站点填多个地址时设为其一（裸 IP 访问必需）

# —— 可选 ——
# RST_AUDIT_ENABLED=false               # 审计默认开启（有数据库时）；设 false 关闭，见 13.4
# RST_DISCOVERY_INTERVAL_SECONDS=3600   # 设备自动发现间隔（秒），默认每小时一次，最小 300，0 关闭定时（手动按钮仍可用）
# RST_MASKING_MODE=cloud                # 脱敏档位，默认按许可推导；本地模型时可关脱敏
# RST_CONTENT_PUBLIC_KEY_PATH=/certs/content_public.pem
# RST_CONTENT_AUTO_APPLY=0              # 新内容包只保存不自动启用，见 14
```

> `deploy.sh` 会自动生成密钥、口令 hash 和指纹文件；手动填时以上为最小集。

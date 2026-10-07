# Release Notes

Customer-facing changes per release. Versions are the gateway image tag
(`GATEWAY_IMAGE_TAG` in `docker-compose.prod.yml`), which is also what the
delivery archive is named after.

---

## 0.1.0 — 2026-10-07

First preview of RST AI Copilot for Prometheus, an AI copilot for network operations (switches, routers and
firewalls monitored with snmp_exporter and blackbox_exporter). For demos and pilots, not for production.

- **Data sources**: connects to your existing Prometheus and Alertmanager; Grafana is optional and used for links.
  Addresses and Basic / Bearer credentials are asked by `deploy.sh` or set later under Settings → Data sources,
  with a connection test before saving.
- **Storage**: one bundled PostgreSQL 16 with pgvector (`pgvector/pgvector:pg16`) holds accounts, audit events,
  report history, the notification outbox and knowledge-base vectors. A customer PostgreSQL can be used instead
  through `RST_DB_URL`.
- **Reports**: daily and weekly network operations reports (alert overview, top-utilised links, errors and
  discards, device availability, capacity risk, AI investigation summaries) with history, schedules and export.
- **Notifications**: Feishu, DingTalk, WeCom, email and webhook. Only AI output is delivered (investigation
  conclusions, reports); alert routing stays with Alertmanager.
- **Deployment**: Caddy TLS front end, optional OIDC single sign-on, an offline all-in-one bundle with SHA-256
  checksum, and `docker-compose.lab-demo.yml`, which layers 30 simulated network devices on the deployment stack
  for demos.
- **Roles**: `admin`, `operator`, `viewer`.
- **Product name**: the product is now called RST AI Copilot for Prometheus. Image, bundle, repository and
  configuration names are unchanged (`rst-prometheus-ai-copilot-*`, `RST-Prometheus-AI-Copilot-*`).
- **EULA 1.1** (effective 2026-10-06): aligned with the other Reallysec products: Chinese text prevails, liability
  cap (Paid Editions: fees paid in the prior 12 months; Community, trial and preview: the greater of fees paid and
  RMB 50), warranty for the Subscription Term, IP indemnity for Paid Editions, audit terms, export control and
  sanctions, privacy and cross-border sections, and a verified list of what the gateway sends outside your
  network. Every user now confirms the EULA at first sign-in and after each EULA version change; acceptances are
  stored in PostgreSQL and in the audit log.
- **Content packs**: `RST_CONTENT_AUTO_APPLY=0` stores newer content packs without activating them, so an
  administrator decides when to switch.
- **Model endpoint**: there is no built-in default any more; `LLM_BASE_URL` (or `llm_providers.yml`) must name the
  endpoint, otherwise no model is configured. A model is optional: without one, queries fall back to keyword
  generation and are marked low-confidence; `deploy.sh` lets you skip it and configure it later in Settings.
- **EULA dialog**: a 中文 | English switch shows either language of the agreement whatever the browser language.
- **Device discovery**: runs hourly; an empty or failed run (for example right after installation, before
  Prometheus has data) is retried after 5 minutes.

Known limits of the preview: several pages are still being reworked for network operations; the edition matrix
for this product is not final.

<!-- zh -->

RST AI Copilot for Prometheus 首个预览版：面向网络运维（交换机、路由器、防火墙，用 snmp_exporter 和 blackbox_exporter
采集）的 AI 副驾。用于演示和试点，不建议用于生产。

- **数据源**：连接已有的 Prometheus 和 Alertmanager，Grafana 可选（用于跳转链接）。地址和 Basic / Bearer 认证由
  `deploy.sh` 询问，也可以之后在「设置 → 数据源连接」里填，保存前先测连通。
- **存储**：自带一套 PostgreSQL 16 + pgvector（`pgvector/pgvector:pg16`），存账号、审计事件、报表历史、通知出站队列和
  知识库向量；也可以通过 `RST_DB_URL` 改用客户自己的 PostgreSQL。
- **报表**：网络运维日报、周报（告警概况、利用率 TOP 链路、错包 / 丢包、设备可用率、容量风险、AI 调查结论摘要），
  支持历史、定时生成和导出。
- **通知**：飞书、钉钉、企业微信、邮件、Webhook。只投递 AI 产出（调查结论、报表），告警路由仍由 Alertmanager 负责。
- **部署**：Caddy TLS 入口、可选 OIDC 单点登录、带 SHA-256 校验的离线一体包，以及 `docker-compose.lab-demo.yml`：
  在部署栈上叠加 30 台模拟网络设备做演示。
- **角色**：`admin`（管理员）、`operator`（运维工程师）、`viewer`（只读）。
- **产品名称**：产品更名为 RST AI Copilot for Prometheus。镜像、交付包、仓库和配置名称不变
  （`rst-prometheus-ai-copilot-*`、`RST-Prometheus-AI-Copilot-*`）。
- **EULA 1.1**（2026-10-06 生效）：与斯普朗克其他产品对齐：以中文文本为准；责任上限（付费版本为前 12 个月实付，
  社区版、试用和预览功能为实付与人民币 50 元取高）；付费版本订阅期内担保；付费版本知识产权赔偿；审计条款；出口
  管制与制裁；隐私与数据出境条款；以及按代码核实的数据外发清单。每位用户首次登录及 EULA 版本变更后都需勾选同意，
  同意记录写入 PostgreSQL 和审计日志。
- **内容包**：`RST_CONTENT_AUTO_APPLY=0` 时较新的内容包只保存不启用，由管理员决定何时切换。
- **模型端点**：不再有内置默认端点，须通过 `LLM_BASE_URL`（或 `llm_providers.yml`）指定，否则视为未配置模型。
  模型是可选的：不配时查询退回关键词生成并标为低可信度；`deploy.sh` 可以跳过，之后在「设置」里再配。
- **EULA 弹窗**：可在「中文 | English」之间切换协议正文，不受浏览器语言限制。
- **设备自动发现**：每小时一次；某次结果为空或失败（例如刚安装、Prometheus 还没有数据）时，5 分钟后重试。

预览版已知限制：部分页面仍在按网络运维场景改造；本产品的版本功能矩阵尚未最终确定。

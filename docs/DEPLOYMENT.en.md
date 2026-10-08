# Deployment guide — RST AI Copilot for Prometheus

For implementers and operators. This is the **authoritative deployment guide**; backup details are in
[`BACKUP.md`](BACKUP.md), license terms in [`EULA.md`](EULA.md). 中文：[`DEPLOYMENT.md`](DEPLOYMENT.md).

> 0.1.0 is a preview for demos and pilots.

---

## 1. Overview

- **Purpose**: an AI copilot for network operations. The devices are switches, routers and firewalls; their
  metrics are collected into Prometheus by snmp_exporter (SNMP) and blackbox_exporter (ICMP / TCP / HTTP probes).
- **Shape**: Docker only. Three containers: gateway, PostgreSQL (pgvector) and Caddy. The license gates and the
  paid engines are Cython-compiled into the image.
- **No Prometheus inside**: the gateway connects to the customer's **existing Prometheus and Alertmanager**;
  Grafana is optional (used for links only). Without a live network, layer the network lab on top (§9).
- **Editions**: one bundle. Without activation it runs as the free Community edition (1 user); Professional and
  Enterprise are activated in the UI (§10).
- **Single replica, built-in login by default**; multiple users and SSO in §13.

```
operator browser ──HTTPS(443)──▶ Caddy ──HTTP(internal)──▶ AI gateway (FastAPI)
                                 TLS                        │
                                                            ├─▶ PostgreSQL + pgvector (same compose project)
                                                            ├─▶ customer Prometheus :9090 / Alertmanager :9093
                                                            ├─▶ model endpoint (Volcengine Ark / self-hosted) :443
                                                            ├─▶ notification channels (Feishu / DingTalk / WeCom / email / webhook)
                                                            └─▶ license.reallysec.com :443 (activation / heartbeat / updates)
```

Containers: `rst-ai-copilot-for-prometheus-gateway`, `rst-ai-copilot-for-prometheus-postgres`, `rst-ai-copilot-for-prometheus-caddy`.

---

## 2. Requirements

| Item | Requirement |
|---|---|
| OS | x86_64 Linux: Ubuntu 20.04 / 22.04 / 24.04, RHEL / CentOS 8+, Kylin, UOS or any distribution that runs Docker 24+ |
| Runtime | Docker Engine **24+** and Docker Compose **v2** (the `docker compose` plugin), bash 4+. `deploy.sh` checks both |
| CPU / memory | 2 vCPU / 4 GB minimum (the gateway container is capped at 2 CPU / 2 GB by default, see `RST_GATEWAY_CPUS` / `RST_GATEWAY_MEM`); 4 vCPU / 8 GB with the network-lab demo |
| Disk | 20 GB+ (images, PostgreSQL data, state) |
| Prometheus | 2.43 or later, reachable from the gateway host; HTTP API (`/api/v1/*`); Basic / Bearer auth and private CAs are supported |
| Alertmanager | 0.25 or later with API v2 (read alerts, create / expire silences) |
| Grafana | optional, 9 or later; only the operators' browsers need to reach it |
| Collection | snmp_exporter, blackbox_exporter (vendors are recognised by `sysObjectID`, see §8) |
| Model | `LLM_API_KEY` / `LLM_BASE_URL` / `LLM_MODEL`: Volcengine Ark, any OpenAI-compatible endpoint, local vLLM / Ollama |
| Access name | **host name or IP** (see §3); the certificate is self-signed by default |
| License | none for Community; Professional / Enterprise are activated in the UI (§10) |

---

## 3. Firewall: ports and host names

**Inbound** (to the gateway host):

| Port | Protocol | Source | Purpose |
|---|---|---|---|
| 443 | TCP | operator network | `https://<host>/v2/`, the only entry point |
| 80 | TCP | operator network | HTTP → HTTPS redirect (optional) |

> Gateway port 8000 and PostgreSQL 5432 are **not published**; they live on the internal compose network.
> On a cloud VM open 443 in the **security group** as well.

**Outbound** (from the gateway host):

| Destination | Port | Purpose | Required |
|---|---|---|---|
| customer Prometheus | 9090 (or proxy port) | metric queries, PromQL validation, rule status | ✅ |
| customer Alertmanager | 9093 (or proxy port) | read alerts, create / expire silences | ✅ |
| model endpoint (e.g. `ark.cn-beijing.volces.com`) | 443 | inference and embeddings | ✅ |
| `license.reallysec.com` | 443 | activation and heartbeat (with a license; not with an offline license) | with a license |
| notification channels (`open.feishu.cn`, `oapi.dingtalk.com`, `qyapi.weixin.qq.com`, SMTP, your webhook) | 443 / 25 / 465 / 587 | deliver investigation conclusions and reports | when used |
| `github.com`, `release-assets.githubusercontent.com` | 443 | online update: daily version check, bundle download | when used |

Grafana is not in the outbound list: the gateway only builds browser links to it and never calls its API.

**Site address**: set `CADDY_SITE_ADDRESS` to the host name or IP the operators use. A **bare IP**
(`https://10.250.1.82/v2/`) works too: a browser sends no SNI to an IP literal, so Caddy falls back to
`default_sni` (`CADDY_DEFAULT_SNI`, which defaults to the site address). `deploy.sh` writes both; when editing by
hand with several space-separated addresses in `CADDY_SITE_ADDRESS`, set `CADDY_DEFAULT_SNI` to one of them.

**Certificate**, chosen by `CADDY_TLS` in `.env` (an upgrade never overwrites it):

| `CADDY_TLS` | Effect |
|---|---|
| `internal` (default) | **self-signed** certificate from Caddy's internal CA, for IPs and host names; distribute the root certificate to operator machines (`docker exec rst-ai-copilot-for-prometheus-caddy cat /data/caddy/pki/authorities/local/root.crt`) |
| `/etc/caddy/certs/cert.pem /etc/caddy/certs/key.pem` | your own certificate: put `cert.pem` and `key.pem` into `./certs` in the install directory |
| `you@example.com` | Let's Encrypt: needs a public DNS name with 80/443 reachable from the internet |

Apply with `docker compose -f docker-compose.prod.yml up -d caddy`.

---

## 4. Get the bundle

The all-in-one bundle `RST-AI-Copilot-for-Prometheus-<version>.tar.gz` holds the image tar (gateway, Caddy,
`pgvector/pgvector:pg16`) and every deployment file (compose files, Caddyfiles, `.env.example`, `deploy.sh`, the
`deploy/` update scripts, the `scripts/` backup scripts, `docs/`). Every edition is the same bundle, shipped with a
`.sha256` file:

```bash
sha256sum -c RST-AI-Copilot-for-Prometheus-<version>.tar.gz.sha256
```

Offline hosts: download and verify on a connected machine, then copy the bundle and its `.sha256` over. The bundle
contains every image, so deployment never needs a registry.

---

## 5. Install Docker (target host)

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER          # log out and back in
docker version && docker compose version
```

On an offline host install Docker Engine 24+ and the Compose plugin from your distribution's offline packages.

---

## 6. Install

Unpack the bundle into a fixed directory (`/opt/rst-ai-copilot-for-prometheus` is recommended; upgrades unpack into the
same directory) and run `deploy.sh`:

```bash
sudo mkdir -p /opt/rst-ai-copilot-for-prometheus
sudo tar xzf RST-AI-Copilot-for-Prometheus-<version>.tar.gz -C /opt/rst-ai-copilot-for-prometheus --strip-components=1
cd /opt/rst-ai-copilot-for-prometheus && sudo ./deploy.sh
```

`deploy.sh` walks through (prompts are bilingual):

1. **Preflight**: Docker 24+ / Compose v2; creates `state/machine-id` and `state/server_guid` (the two halves of the
   license host fingerprint; **never regenerate them**).
2. **`docker load`** of the image tar in the bundle.
3. **Login**: 1 = built-in `/v2` login; 2 = SSO (OIDC, **requires an Enterprise license**).
4. **Model** endpoint, key and model id, and the **time zone** (default `+08:00`; the model reads "today" and
   "yesterday" against it).
5. **Data sources**, each optional (fill them later under Settings → Data sources):
   - Prometheus URL with auth "none / Basic (username + password) / Bearer token";
   - Alertmanager URL, same auth choices;
   - Grafana URL (as the browser reaches it) and the UID of its Prometheus data source (default `prometheus`).
     Grafana has no auth question: the gateway only builds links, and the operator's own Grafana session opens them.
6. **Access host name or IP**; with the built-in login, the **`admin` password** (8+ characters, stored as
   `RST_ADMIN_PASSWORD_HASH`); with SSO, the OIDC issuer, client id and client secret.
7. Generates the internal secrets (gateway shared secret, admin token, PostgreSQL password), asks for confirmation
   and writes `.env` (mode 600).
8. `docker compose -f docker-compose.prod.yml up -d`, waits for every service to be healthy and prints the URL and
   next steps.

Re-running `deploy.sh` and choosing "keep the existing .env" only loads new images and recreates the containers.
Choosing to replace it backs the old file up as `.env.<timestamp>.bak` and keeps the PostgreSQL password (the data
volume was initialised with it).

**Manual path**: `cp .env.example .env`, fill in the required keys (§18), then
`docker load < RST-AI-Copilot-for-Prometheus-images-<version>.tar` and `docker compose -f docker-compose.prod.yml up -d`.

**Your own PostgreSQL**: PostgreSQL 16 with the pgvector extension. Point `RST_DB_URL` in `.env` at it and start only
the gateway and Caddy: `docker compose -f docker-compose.prod.yml up -d --no-deps gateway caddy`. The gateway creates
its tables on start; migrations only touch this product's own tables.

---

## 7. Smoke test

```bash
curl -k https://copilot.corp.local/healthz     # → {"status":"ok"}
curl -k https://copilot.corp.local/readyz      # check db / prometheus
```

- `/healthz`: the process is alive.
- `/readyz` needs the database and Prometheus. `prometheus_configured: false` means the data sources are not set yet,
  which is expected until you fill them in on the Settings page.
- After signing in, press "Test" for each data source under Settings → Data sources; Prometheus and Alertmanager
  answer with their versions.

---

## 8. Preparing the data sources

**Prometheus**

- The gateway uses the read-only HTTP API: `/api/v1/query`, `query_range`, `series`, `labels`, `metadata`,
  `targets`, `rules`, `status/*`. If a reverse proxy authenticates in front of Prometheus, give the gateway a
  read-only account (Basic or Bearer).
- Private CA: put the CA into `./certs` and set `RST_PROMETHEUS_CA_CERT=/certs/ca.pem`; do not turn verification off.
- **Label conventions** (the network content pack relies on them): snmp scrape jobs have a `job` starting with
  `snmp`; the blackbox probe and the snmp scrape of the same device share one `instance`; `site` / `role` / `vendor`
  target labels are optional and are carried into recording rules and alerts when present.
- **Vendor recognition**: by the enterprise-number prefix of `sysObjectID`. Huawei, H3C, Cisco, Ruijie, Juniper,
  Fortinet, Sangfor and others use their private MIBs; anything unrecognised falls back to IF-MIB, ENTITY-MIB,
  ENTITY-SENSOR-MIB and HOST-RESOURCES-MIB.
- **Device-inventory metrics (required)**: the network rule pack depends on three `rst_*` metrics exported from the
  device inventory (interface alert policy, firewall session capacity, HA flag), served by the Copilot at
  `/metrics/inventory`. The customer's Prometheus is usually not part of this product's compose, so add a scrape job
  to its `prometheus.yml` (use the Copilot's address; add `authorization` when `RST_METRICS_TOKEN` is set):

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

  Without it, interface-down alerts fall back to the default policy (non-empty `ifAlias` only), firewalls never
  report "near session capacity" and HA alerts stay silent. The Prometheus in the dev stack (`deploy/dev/prometheus`)
  and the lab demo (`deploy/lab-demo`) already carries this job.
- **Alert-rule write-back** (optional): rules the Copilot generates are written, after approval, into its own rule
  file; Prometheus has to load that directory and run with `--web.enable-lifecycle` for hot reloads.

**snmp_exporter configuration**

The network content pack's metric names and labels follow `deploy/snmp_exporter/snmp.yml`, generated by the
official generator from public MIBs, with module names matching `vendors.yaml`. Use it as-is for the customer's
snmp_exporter (keep community strings / SNMPv3 in a separate `auths.yml`) and pick modules per device type;
regenerate on site when adding vendor MIBs. Sangfor AF has no public MIB: `sangfor.snmp.yml` is an unverified
placeholder until the MIB is exported from the AF UI (System Settings → Download MIB) and the config regenerated.
Steps: `deploy/snmp_exporter/README.md`; verification record: `docs/MIB-VERIFICATION.md`.

**Alertmanager**

- The gateway reads `/api/v2/alerts` and `/api/v2/status` and reads / writes `/api/v2/silences` (every silence is
  audited).
- **Alert routing stays where it is**: grouping, inhibition and paging remain in Alertmanager's own `route` /
  `receivers`. The Copilot's notification module only delivers AI output (§12) and never re-sends alerts.

**Grafana** (optional): `GRAFANA_URL` is the address the browser opens, `GRAFANA_DATASOURCE_UID` the UID of the
Prometheus data source in that Grafana. Alerts and query results then get "Open in Grafana" links.

---

## 9. Network-lab demo (layered on the deployment stack)

For demos, pilots and trainings without live devices, `docker-compose.lab-demo.yml` layers the repository's network
lab (`lab/`) on the deployment stack: 30 simulated devices (13 vendors plus one standard-MIB device, SNMP served by
snmpsim), snmp_exporter and blackbox_exporter, plus a Prometheus (loading `lab/prometheus/scrape-*.yml` and the
product's network rule pack), an Alertmanager (receives, never sends) and a Grafana, with the gateway's data sources
pointed at them.

```bash
# In the install directory (or the repository root), after deploy.sh has written .env
# (leave the data-source questions blank; the overlay fills them in):
docker compose -f docker-compose.prod.yml -f docker-compose.lab-demo.yml up -d --build
```

- `--build` is needed once: the snmpsim image is built from `lab/sim`. The overlay needs `lab/` and
  `app/backend/content/network/rule_pack/`, which are not in the delivery bundle, so demos usually run from a
  repository checkout.
- Copilot: `https://<CADDY_SITE_ADDRESS>/v2/`; Grafana: `http://<host>:23000/` (anonymous viewer; change the port
  with `LAB_DEMO_GRAFANA_PORT` and the browser link with `LAB_DEMO_GRAFANA_URL`).
- `lab/`'s own `lab-prometheus` and `lab-alertmanager` start as well (host ports 19090 / 19093, change with
  `LAB_PROMETHEUS_PORT` / `LAB_ALERTMANAGER_PORT`); the gateway does not use them.
- Fault scenarios (link down, saturation, interface errors, …): `sh lab/scenario.sh on <scenario>`, then
  `off <scenario>`; see `lab/README.md`.
- Stop: `docker compose -f docker-compose.prod.yml -f docker-compose.lab-demo.yml down` (add `-v` to drop the data).

On a development machine the dev stack works too:
`LAB_DIR=./lab docker compose -f docker-compose.yml -f lab/docker-compose.lab.yml up -d --build`; the dev Prometheus
already loads the lab scrape configuration.

---

## 10. Activate a license (bound to this host)

**Community needs no activation** (1 user). For Professional, Enterprise or a trial:

Sign in as **admin** at `https://<host>/v2/` → **License** in the sidebar (`/v2/license`). Only admins can activate.

**Online** (default, needs outbound `license.reallysec.com:443`):

1. Paste the license key on the "Online" tab.
2. Click **Activate**; the status turns "valid" and the license binds to this host's fingerprint.

**Offline** (Enterprise, for hosts without internet access):

1. On the "Offline" tab copy the **host fingerprint**.
2. Give it to the vendor and receive an offline license file (`.lic`) bound to that fingerprint.
3. Upload the file and **Activate**; it is verified locally.

> ⚠️ **Never regenerate `state/machine-id` / `state/server_guid`**: new files mean new hardware and a new activation.

---

## 11. Access and passwords

```
https://copilot.corp.local/v2/
```

Sign in as `admin` with **the password set during deployment**. Without `RST_ADMIN_PASSWORD_HASH` in `.env` the
gateway refuses every login that comes through the browser (Caddy) and warns on every start.

**Forgotten / changed admin password** (single-account install), in the install directory:

```bash
docker exec rst-ai-copilot-for-prometheus-gateway python -m backend.session_auth '<new password>'
# put the output into RST_ADMIN_PASSWORD_HASH= in .env, writing every $ as $$
docker compose -f docker-compose.prod.yml up -d gateway
```

Changing it signs out every open session. With multiple accounts, admins reset others' passwords on the Users page.

---

## 12. Reports and notifications

- **Reports** (`/v2/reports`): daily and weekly network operations reports covering the alert overview, top-utilised
  links, errors and discards, device availability, capacity risk and summaries of AI investigations. Generate on
  demand or on a schedule; the history is kept in PostgreSQL and can be exported.
  Capacity risk: the Community edition lists the current utilization ranking only; Professional fits the trend over
  the report period (daily 1 day, weekly 7 days, monthly 30 days) and extrapolates it, and objects with less history
  than the fit window read "insufficient data" instead of a forecast.
- A notification target has two independent switches, "Subscribe to AI findings" (investigation conclusions) and
  "Receive alert escalations" (alert clusters escalated from triage).
- **Notifications** (`/v2/notify`): Feishu, DingTalk, WeCom, email and webhook. **Only AI output is delivered**:
  investigation conclusions and daily / weekly reports. This is not alert routing and does not forward Alertmanager
  alerts; paging stays with Alertmanager, so nobody receives the same alert twice. Deliveries go through an outbox in
  PostgreSQL with backoff retries; after the last attempt they are dead-lettered and can be re-queued from the page
  once the channel is fixed.
- Webhook URLs, signing secrets and the SMTP password are stored encrypted (key in `.rst_secret_key` on the
  `gateway_state` volume) and never shown back in the UI.

---

## 13. Multiple users and SSO

Community has one user (admin). Professional and Enterprise licenses carry a seat count, `max_users`; the gateway
keeps the number of **enabled** accounts within it.

Pick one of two paths depending on whether the customer has an IdP; **never both**.

### 13.1 Accounts managed by the gateway

Accounts live in the same PostgreSQL, no extra setup. On first start `RST_ADMIN_USERNAME` /
`RST_ADMIN_PASSWORD_HASH` become the first administrator. Admins then add, re-role and disable accounts on the Users
page, **effective immediately**.

### 13.2 SSO (Enterprise)

**Requires an Enterprise license** (`sso_oidc`). Choose login option 2 in `deploy.sh`, or use
`docker-compose.sso.yml` (Caddy → oauth2-proxy → gateway). Register an OIDC client at the IdP with redirect URI
`https://<host>/oauth2/callback` and set `OIDC_ISSUER_URL`, `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`,
`OAUTH2_PROXY_REDIRECT_URL`, `OAUTH2_PROXY_COOKIE_SECRET` (`openssl rand -base64 32`), `OAUTH2_PROXY_COOKIE_SECURE=true`,
`OAUTH2_PROXY_REVERSE_PROXY=true` and `OAUTH2_PROXY_SKIP_OIDC_DISCOVERY=false` (`deploy.sh` writes all of them).
The SSO stack bundles the same `pgvector/pgvector:pg16` with the same `RST_DB_URL`.

The `--profile bundled-idp` services (Keycloak + OpenLDAP) are **a demo / test fixture only**: they listen on
`127.0.0.1` and refuse to start without `KEYCLOAK_ADMIN_PASSWORD`. Do not use them in production.

### 13.3 Roles

| Role | Can do |
|---|---|
| `admin` | everything, including users, license and AI settings |
| `operator` | everything except users, license and AI settings: queries, investigations, deploying alert rules (single approval), silences, settings |
| `viewer` | read-only; every write request except signing in / out and changing one's own password returns 403 |

Under SSO roles come from IdP groups:

```bash
RST_RBAC_ADMIN_GROUPS=netops-admins
RST_RBAC_OPERATOR_GROUPS=netops-l1,netops-l2
RST_RBAC_VIEWER_GROUPS=auditors
```

A user in several groups gets the highest role.

### 13.4 Audit

When the database is available, audit is **on by default**: every write (rule deployment, creating / expiring silences,
settings, user and license changes, and so on) and every model call is recorded in PostgreSQL and shown on the Audit
log page. To turn it off, set `RST_AUDIT_ENABLED=false` in `.env` (`0` / `no` also work) and recreate the gateway
container with `docker compose up -d`. Without a database nothing is recorded.

**EULA acceptance**: every account (SSO users included) confirms the EULA at first sign-in and after each EULA
version change; until then business endpoints answer 403. Acceptances (account, time, version) are stored in the
PostgreSQL table `rst_eula_acceptances` and audited as `eula_accept`. Without per-user identity (ops token only) an
administrator accepts once for the whole installation.

---

## 14. Upgrade / roll back

**Bundle upgrade** (works offline): unpack the new bundle into **the same install directory** and re-run
`deploy.sh`, choosing "keep the existing .env". It loads the new images and moves `GATEWAY_IMAGE_TAG` to the new
version. `.env`, `state/` and the volumes stay; the fingerprint does not change and no re-activation is needed. The
gateway migrates the database schema on start.

**Upgrading from 0.1.x to 0.2.0 (once, by hand)**: from 0.2.0 the bundle, its top directory, the images and the
containers are named `RST-AI-Copilot-for-Prometheus-*` / `rst-ai-copilot-for-prometheus-*`. A 0.1.x gateway looks for
the old file name, so **online update cannot reach 0.2.0**. Upgrade by hand once; online updates work again after that:

- Connected host: `curl -fsSL https://github.com/Reallysec/RST-AI-Copilot-for-Prometheus/releases/latest/download/install.sh | sudo bash`.
  It finds `.env` in the old directory `/opt/rst-prometheus-ai-copilot` and upgrades there.
- Offline host: unpack the 0.2.0 bundle into **the existing install directory** (default `/opt/rst-prometheus-ai-copilot`)
  and re-run `deploy.sh`, choosing "keep the existing .env".

**Do not move the install directory**: its name is the compose project name, which names the data volumes, and
`state/server_guid` lives in it. A new directory starts with empty volumes: the data seems lost, the fingerprint
changes and the license must be activated again. Only new installs use `/opt/rst-ai-copilot-for-prometheus`. The
containers are recreated under the new names (same volumes); the backup and restore scripts find either name.

**Online update**, in two steps (signed, health-gated):

1. **Gateway**: the heartbeat announces a new version → start the download on the License / update page. Signature
   and per-artifact sha256 are checked, fail-closed, into `./release/staging`.
2. **Host**:
   ```bash
   ./deploy/rst-update.sh              # load the staged image → switch GATEWAY_IMAGE_TAG → health probe
   ./deploy/rst-update.sh --rollback   # back to the previous version
   ```
   Success needs three consecutive 200s from `/healthz`, otherwise it **rolls back automatically**. The compose files
   and Caddyfiles from the bundle replace the installed ones (old files kept as `*.bak` and restored on rollback);
   `.env` and `./certs` are left alone.

Back up first (§15), PostgreSQL in particular: migrations are one-way, and rolling back the image does not roll back
the schema.

**Content packs**: when the daily update check finds a newer signed content pack, it is verified and activated by
default. To decide yourself, set `RST_CONTENT_AUTO_APPLY=0` in `.env`: new packs are only stored, and an administrator
activates one with `POST /api/admin/content/rollback/<version>` (which also returns to an earlier pack);
`GET /api/admin/content/status` lists the stored versions.

---

## 15. Backup

Back up:

- `.env` and `./state/` (machine-id + server_guid, the two halves of the fingerprint)
- the `gateway_state` volume (settings, model configuration, activation record, encryption key)
- the `pg_data` volume (PostgreSQL: accounts, audit, report history, notification deliveries, knowledge-base vectors)
- the `caddy_data` volume (internal CA root; losing it means browsers must trust a new one)

`scripts/backup.sh` takes all of them (run it in the install directory); `scripts/restore.sh` restores. See
[`BACKUP.md`](BACKUP.md).

---

## 16. Troubleshooting

| Symptom | Check |
|---|---|
| `/v2/` does not open | `docker compose -f docker-compose.prod.yml logs caddy gateway`; inbound 443; `CADDY_SITE_ADDRESS` is the name or IP actually used |
| Browser certificate warning | self-signed by default (§3): trust the Caddy root or use your own certificate |
| Remote login refused | `.env` lacks `RST_ADMIN_PASSWORD_HASH`; see §11 |
| TLS handshake fails on a bare IP | caddy must receive `CADDY_DEFAULT_SNI`; `docker restart rst-ai-copilot-for-prometheus-caddy` |
| `/readyz` 503 with `db: unreachable` | `docker compose -f docker-compose.prod.yml ps postgres`; the password in `RST_DB_URL` must equal `RST_DB_PASSWORD` |
| `/readyz` 503, `prometheus` not `ok` | can the gateway reach Prometheus (`docker exec rst-ai-copilot-for-prometheus-gateway curl -s $PROMETHEUS_URL/-/ready`); auth and CA |
| Query errors / empty results | test the data sources on the Settings page; failed PromQL validation shows Prometheus' own error; model key / endpoint |
| Alerts page empty | Alertmanager URL and auth; does Alertmanager itself have active alerts |
| Notifications not delivered | the error in the delivery list on the Notifications page; outbound access to the channel; re-queue once fixed |
| "cannot reach the license server" | outbound `license.reallysec.com:443`; offline hosts use offline activation (§10) |
| Problems after an update | `./deploy/rst-update.sh --rollback` |
| License suddenly invalid | was `state/machine-id` or `state/server_guid` regenerated? |

---

## 17. Uninstall

In the install directory (default `/opt/rst-ai-copilot-for-prometheus`). Back up first (§15) unless you are sure.

```bash
cd /opt/rst-ai-copilot-for-prometheus
# SSO installs use docker-compose.sso.yml instead

# A. remove the containers, keep the volumes (re-running ./deploy.sh here restores everything)
docker compose -f docker-compose.prod.yml down

# B. remove the volumes too: gateway state, database and Caddy certificates are gone for good
docker compose -f docker-compose.prod.yml down -v

# remove the images (use the versions `docker image ls` shows)
docker image rm rst-ai-copilot-for-prometheus-gateway:<version> caddy:2 pgvector/pgvector:pg16

# remove the install directory (including .env and state/)
cd / && sudo rm -rf /opt/rst-ai-copilot-for-prometheus
```

- **The customer's Prometheus / Alertmanager are untouched**: remove rule files and silences the Copilot wrote
  yourself if you no longer want them.
- **License**: uninstalling does not notify the license server; the host's fingerprint still counts as a used node.
  To move hosts, restore `state/` (§15) so the fingerprint stays the same, or ask the vendor to release the old node.

---

## 18. Appendix: key `.env` entries

```bash
# —— Model (optional; unset = keyword fallback, can also be set in Settings) ——
LLM_API_KEY=<key>
LLM_BASE_URL=https://ark.cn-beijing.volces.com/api/v3   # required when a model is configured; no built-in default
LLM_MODEL=<model or endpoint id>
RST_TIMEZONE=+08:00

# —— Data sources (may stay empty; fill them in under Settings → Data sources) ——
PROMETHEUS_URL=http://prometheus.corp.local:9090
# PROMETHEUS_USER= / PROMETHEUS_PASSWORD=     or  PROMETHEUS_BEARER_TOKEN=
# RST_PROMETHEUS_CA_CERT=/certs/ca.pem        # private CA
ALERTMANAGER_URL=http://alertmanager.corp.local:9093
# ALERTMANAGER_USER= / ALERTMANAGER_PASSWORD= or  ALERTMANAGER_BEARER_TOKEN=
GRAFANA_URL=https://grafana.corp.local       # as the browser reaches it; links only
GRAFANA_DATASOURCE_UID=prometheus

# —— PostgreSQL (bundled pgvector/pgvector:pg16; same password in both) ——
RST_DB_PASSWORD=<openssl rand -hex 32>
RST_DB_URL=postgresql://rst:<same>@postgres:5432/rst

# —— Gateway auth (required, 32+ random characters each) ——
RST_GATEWAY_SHARED_SECRET=<openssl rand -hex 32>
RST_ADMIN_TOKEN=<openssl rand -hex 32>
RST_ADMIN_PASSWORD_HASH=<docker exec rst-ai-copilot-for-prometheus-gateway python -m backend.session_auth 'PWD', every $ as $$>

# —— Caddy (required) ——
CADDY_SITE_ADDRESS=copilot.corp.local   # host name or IP
# CADDY_DEFAULT_SNI=                    # one of the addresses when several are listed (needed for bare IPs)

# —— Optional ——
# RST_AUDIT_ENABLED=false               # audit is on by default (with a database); false turns it off, see 13.4
# RST_DISCOVERY_INTERVAL_SECONDS=3600   # device auto-discovery interval, default hourly, minimum 300, 0 = no schedule (manual button still works)
# RST_MASKING_MODE=cloud                # masking level; defaults from the license; can be off with a local model
# RST_CONTENT_PUBLIC_KEY_PATH=/certs/content_public.pem
# RST_CONTENT_AUTO_APPLY=0              # store new content packs without activating them, see 14
```

> `deploy.sh` generates the secrets, the password hash and the fingerprint files; the list above is the minimum for a
> manual install.

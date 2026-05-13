# Langfuse on ti-cloud TKE

Self-hosted Langfuse v3 deployment for observing Claude Code / teamai skill execution.

Public URL: <http://langfuse.jmpti.woa.com>

- **Namespace**: `ti-cloud-teamai`
- **Gateway**: shared `ti-cloud/eg-tke` (HTTP port 80, hostname `*.jmpti.woa.com`)
- **Storage**: Tencent CBS (`cbs-ssd-sc`) + Tencent COS for object storage
- **PostgreSQL**: external (`21.162.212.10:5432`, user `admin`, db `langfuse`)
- **Redis + ClickHouse + Zookeeper**: bundled via Helm subcharts (Bitnami legacy images)
- **Upstream chart**: forked in-place under `../charts/langfuse/`

---

## Layout

```text
langfuse-k8s/
├── install.sh                         wrapper around helm + kubectl
├── .env.token                         secrets (gitignored, see .env.token.example)
├── charts/langfuse/
│   ├── Chart.yaml                     upstream chart (v3 compatible)
│   ├── values.yaml                    upstream defaults
│   └── values-ticloud.yaml            ti-cloud overlay — committed, no secrets
└── deploy-ticloud/
    ├── README.md                      this file
    └── httproute.yaml                 HTTPRoute → eg-tke/http → langfuse-web:3000
```

`values-ticloud.yaml` carries only non-secret config (storage classes, domain, image
repos, `signUpDisabled`, COS path prefixes). Every secret is injected at install time
via `install.sh` using `--set-string` overrides so nothing sensitive lands in Git.

---

## Prerequisites (one-time)

### 1. Gateway listener

The shared `ti-cloud/eg-tke` Gateway must expose an HTTP listener with a hostname
wildcard that covers `langfuse.jmpti.woa.com`:

```yaml
listeners:
  - name: http
    port: 80
    protocol: HTTP
    hostname: "*.jmpti.woa.com"
    allowedRoutes:
      namespaces:
        from: All
```

Verify:

```bash
kubectl -n ti-cloud get gateway eg-tke -o yaml | grep -A4 "name: http"
```

### 2. PostgreSQL database

Create the `langfuse` database on the shared PG instance (admin user already has
perms; see `.env.token`):

```bash
PGPASSWORD="$POSTGRES_PASSWORD" psql \
  -h 21.162.212.10 -p 5432 -U admin -d postgres \
  -c "CREATE DATABASE langfuse;"
```

### 3. Tencent COS bucket

Empty bucket `langfuse-gf-1256580188` in region `ap-shanghai` with an access
key-pair that has read/write permission. Langfuse will create keys under
`events/`, `media/`, `exports/` prefixes.

### 4. `.env.token`

Copy the example and fill in all values:

```bash
cp .env.token.example .env.token
# edit .env.token — file is gitignored
chmod 600 .env.token
```

Required keys:

| Key | Notes |
|-----|-------|
| `NEXTAUTH_SECRET` | `openssl rand -base64 32` |
| `LANGFUSE_SALT` | `openssl rand -base64 32` |
| `LANGFUSE_ENCRYPTION_KEY` | `openssl rand -hex 32` (exactly 64 hex chars) |
| `REDIS_PASSWORD` | any strong password |
| `CLICKHOUSE_PASSWORD` | **MUST be alphanumeric only** — see Troubleshooting |
| `POSTGRES_HOST` / `POSTGRES_PORT` / `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DATABASE` | external PG |
| `COS_SECRET_ID` / `COS_SECRET_KEY` / `COS_BUCKET` / `COS_REGION` / `COS_ENDPOINT` | Tencent COS |
| `LANGFUSE_BASE_URL` / `LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY` | filled in AFTER first project is created |

---

## Install / upgrade

```bash
# From langfuse-k8s/
./install.sh              # helm dep update + helm upgrade --install + kubectl apply httproute
./install.sh dry-run      # helm template — no cluster changes
./install.sh uninstall    # helm uninstall + delete HTTPRoute (keeps PVCs)
```

Watch progress:

```bash
kubectl -n ti-cloud-teamai get pods -w
```

Expected set when healthy:

```
langfuse-web-*            1/1 Running
langfuse-worker-*         1/1 Running
langfuse-clickhouse-{0,1,2}  1/1 Running
langfuse-zookeeper-{0,1,2}   1/1 Running
langfuse-redis-master-0   1/1 Running
```

Verify HTTPRoute is attached:

```bash
kubectl -n ti-cloud-teamai get httproute langfuse -o jsonpath='{.status.parents[0].conditions}' | jq
# Expect: Accepted=True, ResolvedRefs=True
```

End-to-end probe (from any cluster pod):

```bash
kubectl -n ti-cloud-teamai run curl --rm -it --image=curlimages/curl --restart=Never -- \
  curl -sSI http://langfuse.jmpti.woa.com/
# Expect: HTTP/1.1 200
```

---

## First-time bootstrap

1. Open <http://langfuse.jmpti.woa.com/> and sign up. The first account becomes the
   owner. `signUpDisabled: false` is left on during the bootstrap window.
2. Create an organization + project (e.g. `teamai` / `teamai-default`).
3. Project settings → API keys → **Create new API keys**. Copy the `pk-lf-...`
   and `sk-lf-...` pair into `.env.token`:
   ```bash
   LANGFUSE_PUBLIC_KEY='pk-lf-...'
   LANGFUSE_SECRET_KEY='sk-lf-...'
   ```
4. Surface the same keys in `ti-cloud-teamai/teamai.yaml` under
   `observability.langfuse` so every teammate's `teamai-cli` picks them up.
5. After all owners have signed up, flip `signUpDisabled: true` in
   `values-ticloud.yaml` and re-run `./install.sh`.

---

## Troubleshooting runbook

These are the real failures we hit during rollout — check here before digging.

### CBS `disk size is invalid. Must in [10, 32000]`

Tencent CBS enforces a **10 Gi minimum**, but the Bitnami subchart defaults to
8 Gi. Every PVC on `cbs-ssd-sc` must request ≥ 10 Gi. See `persistence.size`
fields in `values-ticloud.yaml`.

### StatefulSet volumeClaimTemplate is immutable

Changing `persistence.size` on an existing install is rejected by the API
server. To change the storage size you must recreate the StatefulSets (and the
PVCs they own):

```bash
kubectl -n ti-cloud-teamai delete statefulset langfuse-clickhouse --cascade=orphan
kubectl -n ti-cloud-teamai delete statefulset langfuse-zookeeper  --cascade=orphan
kubectl -n ti-cloud-teamai delete statefulset langfuse-redis-master --cascade=orphan
kubectl -n ti-cloud-teamai delete pvc --all
./install.sh
```

### ClickHouse password is stale after you rotate it

Bitnami subcharts generate a one-shot Kubernetes Secret on the **first**
install and never regenerate it on upgrades. If you change
`CLICKHOUSE_PASSWORD` you must drop the Secret first:

```bash
kubectl -n ti-cloud-teamai delete secret langfuse-clickhouse
./install.sh
```

### `+` or `/` in the ClickHouse password breaks migrations

`langfuse-worker` runs `up.sh`, which appends the CH password as a query string
(`?password=...`) without URL-encoding. The go-migrate ClickHouse driver then
decodes `+` → space, silently authenticating with the wrong password and
failing every migration.

**Keep `CLICKHOUSE_PASSWORD` alphanumeric.** Generate with:

```bash
openssl rand -hex 16
```

### PostgreSQL auth fails

`POSTGRES_USER` must be `admin` (the shared cluster account) and the `langfuse`
database must exist already. Quick check from a debug pod:

```bash
PGPASSWORD='...' psql -h 21.162.212.10 -U admin -d langfuse -c "SELECT version();"
```

### `helm dependency update` stdout leaks into `dry-run`

`install.sh` redirects `helm dependency update` stdout → stderr in the
`dry-run` branch so the rendered manifests stay clean. Don't remove that
redirection.

---

## File safety rules

- **Never commit `.env.token`.** It is listed in `.gitignore` (lines 120, 125).
  Double-check `git status` before pushing.
- `values-ticloud.yaml` only carries non-secret config. Add secret overrides to
  `install.sh`, not the values file.
- No secret belongs in `deploy-ticloud/httproute.yaml` — it is safe to commit.

---

## Uninstall

```bash
./install.sh uninstall
# PVCs and namespace are preserved (reclaim=Retain).
# To wipe completely:
kubectl -n ti-cloud-teamai delete pvc --all
kubectl delete ns ti-cloud-teamai
```

PVCs that still exist after `helm uninstall` are your safety net if the admin
account was lost — reinstalling with the same secrets re-attaches the existing
PostgreSQL + ClickHouse + COS data.

# Hanzo Help Center (hanzoai/helpdesk)

Fork of `frappe/helpdesk` deployed as a Hanzo platform service at **help.hanzo.ai**.
Second Frappe app after `hanzoai/erp`, proving the *one Frappe-core -> all Frappe
apps* thesis: the same recipe (`bench` + the `hanzoai/frappe` SQLite driver)
is reused; only the app layer swaps.

## Hanzo-specific additions (vs upstream)
- `Dockerfile` — self-contained, on-cluster build (arcd/BuildKit, never GitHub
  builders). Builds a bench against `hanzoai/frappe` (carries the experimental
  **SQLite** driver), installs `telephony` + `helpdesk`, builds SPA assets, and
  snapshots the built `sites/` tree as an image template (assets = code).
- `deploy/entrypoint.sh` — starts in-pod redis (cache/queue/socketio), restores
  code assets over the data-only volume, creates a **per-org SQLite site**
  (`org == tenant`), wires IAM SSO, and serves via `bench serve` (no nginx —
  hanzoai/ingress terminates TLS + routes the host).
- `helpdesk/hanzo_sso.py` — idempotently provisions a Frappe *Social Login Key*
  for **hanzo.id** OAuth2. Client credentials come from env (KMS-backed k8s
  secret `help-secrets`), never hardcoded.
- `deploy/help.service.yaml` — operator-native Service CR (`hanzo.ai/v1`).
- `deploy/help.ingress.yaml` — ingress (`help.hanzo.ai`) + PVC (`help-app-db`).

## Data model
`org == tenant` (IAM owner). One SQLite site per org on the mounted volume
(Hanzo Base/SQLite). No MariaDB / Postgres / external DB.

## IAM SSO
IAM application: `hanzo-helpdesk` (org `hanzo`) on hanzo.id.
OAuth2 redirect URI to register:
`https://help.hanzo.ai/api/method/frappe.integrations.oauth2_logins.custom/hanzo`
Endpoints (Casdoor-mapped): authorize `/v1/iam/login/oauth/authorize`,
token `/v1/iam/login/oauth/access_token`, userinfo `/v1/iam/userinfo`,
jwks `/v1/iam/.well-known/jwks`.

## Build & deploy (one lifecycle)
1. arcd BuildKit Job -> `ghcr.io/hanzoai/helpdesk:<semver>` (context =
   `github.com/hanzoai/helpdesk#<ref>`, `filename=Dockerfile`).
2. Pin the semver tag in `hanzoai/universe`; operator reconciles the `help`
   Service CR + ingress in ns `hanzo` (context `do-sfo3-hanzo-k8s`).
3. Secrets in KMS -> `help-secrets` (ADMIN_PASSWORD, ENCRYPTION_KEY,
   IAM_CLIENT_ID, IAM_CLIENT_SECRET).

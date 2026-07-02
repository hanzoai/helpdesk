#!/usr/bin/env bash
# Hanzo Help Center runtime entrypoint.
# org == tenant: one SQLite site per org, persisted on the mounted volume.
# No nginx (hanzoai/ingress terminates TLS + routes the host), no external DB.
set -euo pipefail

BENCH_DIR=/home/frappe/frappe-bench
cd "$BENCH_DIR"

SITE_NAME="${SITE_NAME:-help.hanzo.ai}"
HANZO_ORG="${HANZO_ORG:-hanzo}"
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD required (from KMS-backed secret help-secrets)}"

# 1) In-pod redis for cache/queue/socketio. SQLite holds all relational data.
redis-server --daemonize yes --port 6379 --save "" --appendonly no

# 2) Assets are CODE, not data: restore the built sites/ scaffold on top of the
#    (data-only) volume mounted at $BENCH_DIR/sites.
mkdir -p sites
# cp -dR (not -a): preserve symlinks + recurse WITHOUT --preserve=all, which
# would utime the volume mount root (root-owned; fsGroup grants write, not
# ownership) and fail with EPERM.
if [ ! -f sites/apps.txt ]; then
  echo "[entrypoint] fresh volume -> seeding sites/ from image template"
  cp -dR /home/frappe/sites-template/. sites/
else
  echo "[entrypoint] existing volume -> refreshing code assets from image template"
  rm -rf sites/assets
  cp -dR /home/frappe/sites-template/assets sites/assets
  cp -f /home/frappe/sites-template/apps.txt sites/apps.txt
fi

# 3) Common (cross-site) config: redis + socketio.
bench set-config -g redis_cache    "redis://127.0.0.1:6379" >/dev/null
bench set-config -g redis_queue    "redis://127.0.0.1:6379" >/dev/null
bench set-config -g redis_socketio "redis://127.0.0.1:6379" >/dev/null
bench set-config -gp socketio_port 9000 >/dev/null

# 4) Per-org SQLite site (org == tenant), created once, persisted on the volume.
if [ ! -d "sites/${SITE_NAME}" ]; then
  echo "[entrypoint] creating SQLite site ${SITE_NAME} (org=${HANZO_ORG})"
  bench new-site "${SITE_NAME}" \
    --db-type sqlite \
    --admin-password "${ADMIN_PASSWORD}" \
    --install-app telephony \
    --install-app helpdesk \
    --set-default
  [ -n "${ENCRYPTION_KEY:-}" ] && bench --site "${SITE_NAME}" set-config encryption_key "${ENCRYPTION_KEY}"
  bench --site "${SITE_NAME}" set-config host_name "https://${SITE_NAME}"
else
  echo "[entrypoint] site ${SITE_NAME} exists -> migrate"
  bench --site "${SITE_NAME}" migrate
fi
bench use "${SITE_NAME}"

# 5) IAM SSO (hanzo.id OAuth2) — idempotent, secrets from env (KMS-backed).
bench --site "${SITE_NAME}" execute helpdesk.hanzo_sso.setup \
  || echo "[entrypoint] SSO provisioning skipped/failed (non-fatal)"

# 6) Serve. bench serve (werkzeug) serves /assets, /files, /api and proxies
#    /socket.io. Background worker + scheduler + socketio for full function.
echo "[entrypoint] worker + scheduler + socketio + web(:8000) starting"
nohup bench worker --queue default,short,long >/tmp/worker.log 2>&1 &
nohup node apps/frappe/socketio.js            >/tmp/socketio.log 2>&1 &
nohup bench schedule                          >/tmp/schedule.log 2>&1 &
exec bench serve --port 8000

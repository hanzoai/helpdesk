#!/usr/bin/env bash
# Hanzo Help Center runtime entrypoint.
# org == tenant: ONE SQLite site (== one DB) per org, persisted on the mounted
# volume. Frappe resolves the site from the Host header, so per-org DB isolation
# is structural: org A's tickets live in a different SQLite file than org B's.
#   primary org (HANZO_ORG)  -> host SITE_NAME            (e.g. help.hanzo.ai)
#   any other org  <org>     -> host <org>.<SITE_NAME>    (e.g. acme.help.hanzo.ai)
# No nginx (hanzoai/ingress terminates TLS + routes the host), no external DB.
set -euo pipefail

BENCH_DIR=/home/frappe/frappe-bench
cd "$BENCH_DIR"

SITE_NAME="${SITE_NAME:-help.hanzo.ai}"
HANZO_ORG="${HANZO_ORG:-hanzo}"
# Comma-separated org slugs to provision sites for (org == tenant). The primary
# org is always included. Additional orgs get <org>.<SITE_NAME> sites.
HANZO_ORGS="${HANZO_ORGS:-$HANZO_ORG}"
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD required (from KMS-backed secret help-secrets)}"

# Map an org slug to its Frappe site (== Host header == SQLite DB directory).
site_for_org() {
  local org="$1"
  if [ "$org" = "$HANZO_ORG" ]; then
    echo "$SITE_NAME"
  else
    echo "${org}.${SITE_NAME}"
  fi
}

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

# 4) Per-org SQLite site (org == tenant). Created once, persisted on the volume,
#    migrated + (re)hardened on every boot.
provision_site() {
  local org="$1" site
  site="$(site_for_org "$org")"
  if [ ! -d "sites/${site}" ]; then
    echo "[entrypoint] creating SQLite site ${site} (org=${org})"
    bench new-site "${site}" \
      --db-type sqlite \
      --admin-password "${ADMIN_PASSWORD}" \
      --install-app telephony \
      --install-app helpdesk
    [ -n "${ENCRYPTION_KEY:-}" ] && bench --site "${site}" set-config encryption_key "${ENCRYPTION_KEY}"
    bench --site "${site}" set-config host_name "https://${site}"
    bench --site "${site}" set-config hanzo_org "${org}"
  else
    echo "[entrypoint] site ${site} exists (org=${org}) -> migrate"
    bench --site "${site}" migrate
  fi
  # IAM SSO + login hardening (idempotent, secrets from env / KMS-backed).
  bench --site "${site}" execute helpdesk.hanzo_sso.setup \
    || echo "[entrypoint] SSO provisioning skipped/failed for ${site} (non-fatal)"
  # Brand the pages Frappe renders itself — login, navbar, footer, favicon.
  # Each field is set to a constant, so this restores the brand on every boot
  # of a site that already exists just as it sets it on a new one.
  bench --site "${site}" execute helpdesk.brand.setup \
    || echo "[entrypoint] brand provisioning skipped/failed for ${site} (non-fatal)"
}

IFS=',' read -ra _orgs <<< "$HANZO_ORGS"
for _org in "${_orgs[@]}"; do
  _org="$(echo "$_org" | tr -d '[:space:]')"
  [ -n "$_org" ] && provision_site "$_org"
done

# Primary org is the default site for bare/unknown hosts.
bench use "$(site_for_org "$HANZO_ORG")"

# 5) Serve. bench serve (werkzeug) serves /assets, /files, /api and proxies
#    /socket.io. Background worker + scheduler + socketio for full function.
echo "[entrypoint] worker + scheduler + socketio + web(:8000) starting"
nohup bench worker --queue default,short,long >/tmp/worker.log 2>&1 &
nohup node apps/frappe/socketio.js            >/tmp/socketio.log 2>&1 &
nohup bench schedule                          >/tmp/schedule.log 2>&1 &
exec bench serve --port 8000

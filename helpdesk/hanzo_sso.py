"""Hanzo IAM (hanzo.id) OAuth2 SSO provisioning for Frappe Helpdesk.

Idempotently upserts a Frappe "Social Login Key" pointing at the Hanzo IAM
OIDC provider. Client credentials come from the environment (a KMS-backed
Kubernetes secret), never hardcoded. Called by the container entrypoint via
`bench --site <site> execute helpdesk.hanzo_sso.setup`.

Frappe's OAuth callback for a custom provider named "hanzo" is:
    https://<site>/api/method/frappe.integrations.oauth2_logins.custom/hanzo
which is the redirect URI to register on the IAM application (hanzo-helpdesk).
"""

import json
import os

import frappe

PROVIDER = "hanzo"


def setup():
    client_id = os.environ.get("IAM_CLIENT_ID")
    client_secret = os.environ.get("IAM_CLIENT_SECRET")
    base_url = os.environ.get("IAM_BASE_URL", "https://hanzo.id")

    if not client_id or not client_secret:
        print("hanzo_sso: IAM_CLIENT_ID / IAM_CLIENT_SECRET not set; skipping")
        return

    values = {
        "social_login_provider": "Custom",
        "provider_name": PROVIDER,
        "enable_social_login": 1,
        "base_url": base_url,
        "client_id": client_id,
        "client_secret": client_secret,
        "authorize_url": "/v1/iam/login/oauth/authorize",
        "access_token_url": "/v1/iam/login/oauth/access_token",
        "api_endpoint": "/v1/iam/userinfo",
        "auth_url_data": json.dumps(
            {"response_type": "code", "scope": "openid profile email"}
        ),
        "user_id_property": "email",
    }

    if frappe.db.exists("Social Login Key", PROVIDER):
        doc = frappe.get_doc("Social Login Key", PROVIDER)
        doc.update(values)
        doc.save(ignore_permissions=True)
        action = "updated"
    else:
        doc = frappe.get_doc(dict(values, doctype="Social Login Key"))
        doc.insert(ignore_permissions=True)
        action = "created"

    frappe.db.commit()
    print(f"hanzo_sso: {action} Social Login Key '{PROVIDER}' -> {base_url}")

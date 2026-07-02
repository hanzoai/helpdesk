"""Hanzo IAM (hanzo.id) OAuth2 SSO provisioning for Frappe Helpdesk.

Makes Hanzo IAM the ONE identity authority for the Help Center:

1. Idempotently upserts a Frappe "Social Login Key" for the Hanzo IAM OIDC
   provider (endpoints match hanzo.id's published OIDC discovery document).
2. Disables Frappe's native email/password signup (so IAM is the only way in;
   no second identity authority).
3. Forces SSO-only login where the Frappe version supports it.

Client credentials come from the environment (a KMS-backed Kubernetes secret
`help-secrets`), never hardcoded. Called by the container entrypoint via
`bench --site <site> execute helpdesk.hanzo_sso.setup`.

Frappe's OAuth callback for a custom provider named "hanzo" is:
    https://<site>/api/method/frappe.integrations.oauth2_logins.custom/hanzo
which is the redirect URI registered on the IAM application (hanzo-helpdesk).
"""

import json
import os

import frappe

PROVIDER = "hanzo"

# hanzo.id OIDC endpoints — authoritative values from
# https://hanzo.id/.well-known/openid-configuration
AUTHORIZE_URL = "/v1/iam/oauth/authorize"
ACCESS_TOKEN_URL = "/v1/iam/oauth/token"
USERINFO_URL = "/v1/iam/oauth/userinfo"


def setup():
    # Hardening must apply even if social-login provisioning fails, so a broken
    # provider config can never silently leave native signup open.
    try:
        _setup_social_login()
    finally:
        _harden_login()


def _setup_social_login():
    client_id = os.environ.get("IAM_CLIENT_ID")
    client_secret = os.environ.get("IAM_CLIENT_SECRET")
    base_url = os.environ.get("IAM_BASE_URL", "https://hanzo.id")

    if not client_id or not client_secret:
        print("hanzo_sso: IAM_CLIENT_ID / IAM_CLIENT_SECRET not set; skipping")
        return

    # Frappe validates that a Custom provider has a Redirect URL. Derive it from
    # the site's own URL so it is correct per-org (each org's SQLite site sets
    # its own host_name): https://<site>/api/method/.../custom/hanzo
    redirect_url = frappe.utils.get_url(
        f"/api/method/frappe.integrations.oauth2_logins.custom/{PROVIDER}"
    )

    values = {
        "social_login_provider": "Custom",
        "provider_name": PROVIDER,
        "enable_social_login": 1,
        # custom_base_url=1 makes Frappe prepend base_url to authorize/token/
        # userinfo paths; without it the relative paths resolve to the Frappe
        # host and the OAuth redirect breaks.
        "custom_base_url": 1,
        "base_url": base_url,
        "redirect_url": redirect_url,
        "client_id": client_id,
        "client_secret": client_secret,
        "authorize_url": AUTHORIZE_URL,
        "access_token_url": ACCESS_TOKEN_URL,
        "api_endpoint": USERINFO_URL,
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


def _harden_login():
    """Make IAM the ONE identity authority: no native signup, SSO-only login."""
    changed = []
    # Remove native "Sign Up" / "Create Account".
    if _set_single_if_field("Website Settings", "disable_signup", 1):
        changed.append("Website Settings.disable_signup=1")
    # Force SSO: hide the username/password form (Frappe v15+). Guarded so it is
    # a no-op (never an error) on versions without the field.
    if _set_single_if_field("System Settings", "disable_user_pass_login", 1):
        changed.append("System Settings.disable_user_pass_login=1")
    # Disable Frappe's native passwordless email-link login — it is a second
    # (non-IAM) identity path. IAM SSO is the ONLY way in.
    if _set_single_if_field("System Settings", "login_with_email_link", 0):
        changed.append("System Settings.login_with_email_link=0")
    frappe.db.commit()
    print(f"hanzo_sso: hardened login -> {', '.join(changed) or 'no fields present'}")


def _set_single_if_field(doctype: str, fieldname: str, value) -> bool:
    """set_single_value only when the field actually exists on the DocType."""
    meta = frappe.get_meta(doctype)
    if not meta.has_field(fieldname):
        return False
    frappe.db.set_single_value(doctype, fieldname, value)
    return True

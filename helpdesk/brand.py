"""Hanzo Help Center brand for the pages Frappe itself renders.

The desk SPA carries its marks in this repo's source. The login page, the
website navbar and the website footer are rendered by the Frappe core, which
reads its marks from Website Settings / Navbar Settings / System Settings at
run time. Writing those rows is how the Help Center brands those pages — the
core stays untouched.

Called by the container entrypoint on every boot via
`bench --site <site> execute helpdesk.brand.setup`. Every write sets a field
to a constant, so a re-run against an existing site restores the same values.

The marks are served from this app's own public directory
(`helpdesk/public` -> `/assets/helpdesk`), so no page reaches a third-party
host for a logo.
"""

import frappe

NAME = "Hanzo Help Center"
PUBLISHER = "Hanzo AI"
MARK = "/assets/helpdesk/hanzo-mark.svg"
FAVICON = "/assets/helpdesk/hanzo-favicon.svg"

# Single doctype -> {fieldname: value}.
#
# app_logo is set on both Singles because the core reads it from two places:
# `get_app_logo()` (login page, desk toolbar) takes Website Settings first and
# Navbar Settings second, while the desktop page reads Navbar Settings direct.
#
# brand_html is the navbar-brand slot the core reads FIRST, ahead of
# banner_image, so setting it alone makes the navbar mark deterministic;
# banner_image is left empty rather than kept as a second source for one slot.
# The navbar stylesheet already caps a brand image at 22px, so the tag carries
# no sizing of its own.
#
# footer_powered must be non-empty: the footer falls back to the framework's
# own credit line when it is blank.
BRAND = {
    "Website Settings": {
        "app_name": NAME,
        "app_logo": MARK,
        "favicon": FAVICON,
        "brand_html": f'<img src="{MARK}" alt="{NAME}">',
        "footer_powered": PUBLISHER,
    },
    "Navbar Settings": {"app_logo": MARK},
    # The login page falls back to this when Website Settings carries no
    # app_name, and the core ships it defaulted to the framework's name.
    "System Settings": {"app_name": NAME},
}


def setup():
    written = [
        f"{doctype}.{fieldname}"
        for doctype, fields in BRAND.items()
        for fieldname, value in fields.items()
        if _set_single_if_field(doctype, fieldname, value)
    ]
    frappe.db.commit()
    print(f"brand: set {', '.join(written) or 'nothing — no fields present'}")


def _set_single_if_field(doctype: str, fieldname: str, value) -> bool:
    """set_single_value only when the field exists on this Frappe version."""
    if not frappe.get_meta(doctype).has_field(fieldname):
        return False
    frappe.db.set_single_value(doctype, fieldname, value)
    return True

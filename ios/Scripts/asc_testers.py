#!/usr/bin/env python3
# Ported from for-Notes apps/ios/Scripts at 6c199f5; names adapted to ForIT Dictate, logic unchanged.
"""Make sure the people who should see TestFlight builds are in the beta group.

A build attached to a group nobody is in is a build nobody can install. The group
Scripts/asc_resolve.py creates starts empty, so after every upload Scripts/mini-testflight.sh
runs this to put each address in TESTER_EMAILS into it: an existing tester is linked
to the group, an unknown address is created as a tester of the group. Internal
groups only accept App Store Connect team members; the API says so (409) and this
prints that as a warning and exits 0 rather than failing the upload — and the API
cannot link a team member to an internal group either (409 STATE_ERROR "Tester(s)
cannot be assigned", run 33998919457). What App Store Connect does take for an existing
tester is a new tester record created with the group (POST /v1/betaTesters with the
betaGroups relationship, 201; found by for-Health on app 6821459120 and for-Messages,
2026-10-08..10), so on that 409 this creates one, with the team member's names. Only if
that is refused too does it print the warning: then it is a one-time click in App Store
Connect (TestFlight -> Internal Testing -> the group -> Add Testers). A team member with per-app access
(Developer role, e.g. me@bthomas.io) is only offered in that picker once the app is among
their visible apps (POST /v1/users/{id}/relationships/visibleApps, ios/docs/SIGNING.md).
(Ported from for-LMS apps/ios/Scripts, itself from for-Messages, for-CRM and for-Calendar;
logic unchanged.)

Pure logic takes an injected `api` callable (Scripts/test_asc_testers.py).

With --app-id, each address that belongs to a team member with per-app access first
gets the app added to their visible apps (ensure_visible), so the picker offers them.

Usage (env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_BASE64):
  asc_testers.py [--app-id <id>] --group-id <id> --emails "a@x.io, b@x.io"
"""
from __future__ import annotations

import argparse
import base64
import os
import re
import sys
import urllib.parse
from typing import Callable

import asc_resolve

Api = Callable[..., dict]


def parse_emails(raw: str) -> list[str]:
    return [e for e in re.split(r"[,\s]+", raw.strip()) if e]


def ensure_tester(api: Api, group_id: str, email: str) -> str:
    q = urllib.parse.quote(email, safe="")
    if api("GET", f"/betaTesters?filter[email]={q}&filter[betaGroups]={group_id}").get("data"):
        return "already in group"
    known = api("GET", f"/betaTesters?filter[email]={q}").get("data", [])
    if known:
        try:
            api("POST", f"/betaGroups/{group_id}/relationships/betaTesters",
                body={"data": [{"type": "betaTesters", "id": known[0]["id"]}]})
            return "added to group"
        except SystemExit as e:
            if not is_refused_link(str(e)):
                raise
        # The internal group of a new app refuses the link; it takes the tester created
        # again with the group.
        api("POST", "/betaTesters", body=new_tester(group_id, email, team_member_names(api, email)))
        return "created in group"
    api("POST", "/betaTesters", body=new_tester(group_id, email, {}))
    return "created"


def is_refused_link(error: str) -> bool:
    flat = " ".join(str(error).split())
    return "cannot be assigned" in flat or "STATE_ERROR" in flat


def team_member_names(api: Api, email: str) -> dict:
    q = urllib.parse.quote(email, safe="")
    users = api("GET", f"/users?filter[username]={q}").get("data", [])
    attrs = users[0].get("attributes", {}) if users else {}
    return {k: attrs[k] for k in ("firstName", "lastName") if attrs.get(k)}


def new_tester(group_id: str, email: str, names: dict) -> dict:
    return {
        "data": {
            "type": "betaTesters",
            "attributes": {"email": email, **names},
            "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": group_id}]}},
        },
    }


def ensure_visible(api: Api, app_id: str, email: str) -> str:
    """Add the app to a per-app team member's visible apps. The POST adds to the list
    (PATCH would replace it), so a second run changes nothing."""
    q = urllib.parse.quote(email, safe="")
    users = api("GET", f"/users?filter[username]={q}").get("data", [])
    if not users:
        return "not a team member"
    user = users[0]
    if user.get("attributes", {}).get("allAppsVisible"):
        return "sees all apps"
    visible = api("GET", f"/users/{user['id']}/relationships/visibleApps?limit=200").get("data", [])
    if any(a.get("id") == app_id for a in visible):
        return "app already visible"
    api("POST", f"/users/{user['id']}/relationships/visibleApps",
        body={"data": [{"type": "apps", "id": app_id}]})
    return "app made visible"


INTERNAL_GROUP_HINT = (
    "App Store Connect refused to link the tester to the group (409 STATE_ERROR \"Tester(s) "
    "cannot be assigned\"). An internal group only takes App Store Connect team members and "
    "the API does not link them: add the person once in App Store Connect (TestFlight -> "
    "Internal Testing -> the group -> Add Testers); this step then reports them as already "
    "in the group. A Developer with per-app access is only offered there once the app is among "
    "their visible apps (ios/docs/SIGNING.md)."
)


def explain_failure(email: str, error: str) -> str:
    """The one line to print when App Store Connect refuses a tester. One line, because a
    ::warning annotation ends at the first newline and the API body is multi-line JSON."""
    flat = " ".join(str(error).split())
    if is_refused_link(flat):
        return f"::warning title=TestFlight tester not added::{email}: {INTERNAL_GROUP_HINT}"
    return f"::warning title=TestFlight tester not added::{email}: {flat}"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--app-id", help="also make the app visible to per-app team members")
    ap.add_argument("--group-id", required=True)
    ap.add_argument("--emails", required=True, help="comma/space separated")
    args = ap.parse_args(argv)
    emails = parse_emails(args.emails)
    if not emails:
        print("no tester emails configured — nothing to do")
        return 0
    private_key = base64.b64decode(os.environ["ASC_KEY_BASE64"]).decode()
    api = asc_resolve.make_api(os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"], private_key)
    for email in emails:
        if args.app_id:
            try:
                print(f"{email}: {ensure_visible(api, args.app_id, email)}")
            except SystemExit as e:
                print(f"::warning title=App not made visible::{email}: {' '.join(str(e).split())}")
        try:
            print(f"{email}: {ensure_tester(api, args.group_id, email)}")
        except SystemExit as e:  # make_api raises SystemExit on HTTP errors
            print(explain_failure(email, str(e)))
    return 0


if __name__ == "__main__":
    sys.exit(main())

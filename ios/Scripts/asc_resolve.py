#!/usr/bin/env python3
# Ported from for-Notes apps/ios/Scripts at 6c199f5; names adapted to ForIT Dictate, logic unchanged.
"""Resolve the App Store Connect ids a TestFlight upload needs from the bundle id.

Ported from for-LMS apps/ios/Scripts (itself from for-Messages, for-CRM, for-Calendar and for-Squelch, the proven
pattern); logic unchanged, names adapted to ForIT Dictate. When the bundle id is not found, the reason also lists every
app the API key sees (what_the_key_sees).

metered-call-guard: not-metered the App Store Connect API is part of the Apple Developer membership; Apple rate-limits
it per hour and bills nothing per call. Only Scripts/mini-testflight.sh calls it, a few dozen requests a run.

The app's numeric Apple ID and a TestFlight beta group id only exist once the app
record exists in App Store Connect. Nothing headless creates that record: the API
refuses POST /v1/apps (403) and `xcodebuild -exportArchive` with `destination:
upload` fails with "Error Downloading App Information" while it is missing — it is
created once, interactively, in App Store Connect (ios/docs/SIGNING.md). The
ForIT Dictate record is found by bundle id. mini-testflight.sh runs this with
`--require` right before its upload: it finds the app by bundle id, reuses the app's
internal beta group (creating one, "ForIT internal", when the app has no groups yet)
and writes the ids to $GITHUB_OUTPUT (a file the script names) for the testers and
attach steps after the upload. Without `--require` a missing record is a notice and
exit 0, for a caller that only wants to know.

Pure logic lives in `resolve(api, bundle_id, group_name)` so it is unit-tested with
a fake `api` (Scripts/test_asc_resolve.py). Key material is read only in `main()`.
"""
from __future__ import annotations

import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Callable, Optional

ASC_BASE = "https://api.appstoreconnect.apple.com/v1"

# The App Store Connect record's name, and the word that marks a record named like it.
APP_NAME = "ForIT Dictate"
LOOKALIKE_WORD = "dictate"

Api = Callable[..., dict]


class AscError(SystemExit):
    """An App Store Connect HTTP error raised by the `api` callable `make_api` returns.

    A SystemExit, so a script that does not catch it still ends with the message on
    stderr and exit status 1 (what every caller relied on before this class existed);
    a caller that expects a specific status — asc_attach.py and the 422 an internal
    all-builds group answers the attach with — catches it and reads `.status`."""

    def __init__(self, message: str, *, status: int, detail: str):
        super().__init__(message)
        self.status = status
        self.detail = detail


@dataclass
class Resolved:
    ready: bool
    app_id: Optional[str]
    group_id: Optional[str]
    reason: str


def resolve(api: Api, bundle_id: str, group_name: str) -> Resolved:
    apps = api("GET", f"/apps?filter[bundleId]={bundle_id}").get("data", [])
    if not apps:
        return Resolved(
            ready=False, app_id=None, group_id=None,
            reason=(
                f"no App Store Connect app record for bundle id {bundle_id}; it has to be "
                "created once in App Store Connect (My Apps -> + -> New App, iOS, name "
                f"\"{APP_NAME}\", English (U.S.), bundle id {bundle_id}, SKU {bundle_id}) — the upload "
                "cannot create it. " + what_the_key_sees(api, bundle_id)
            ),
        )
    app_id = apps[0]["id"]
    groups = api("GET", f"/betaGroups?filter[app]={app_id}").get("data", [])
    internal = [g for g in groups if g.get("attributes", {}).get("isInternalGroup")]
    group = (internal or groups)[0] if groups else None
    if group is None:
        group = api("POST", "/betaGroups", body={
            "data": {
                "type": "betaGroups",
                "attributes": {"name": group_name, "isInternalGroup": True, "hasAccessToAllBuilds": True},
                "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
            },
        })["data"]
    keep_on_phones(api, group)
    return Resolved(ready=True, app_id=app_id, group_id=group["id"], reason="")


def what_the_key_sees(api: Api, bundle_id: str) -> str:
    """Why the record was not found: every app this API key can see, by name and bundle id, and any "dictate" app
    filed under another bundle id. Tells a record that is not there from one made with the wrong bundle id, or from
    a key that sees no apps at all. Read-only; a refused listing is reported, never raised."""
    try:
        data = api("GET", "/apps?fields[apps]=name,bundleId&limit=200").get("data", [])
    except AscError as e:
        return f"Listing the apps this key sees failed too (HTTP {e.status})."
    seen = [((a.get("attributes") or {}).get("name") or "?", (a.get("attributes") or {}).get("bundleId") or "?")
            for a in data]
    line = f"This API key sees {len(seen)} app(s): " + (", ".join(f"{n} ({b})" for n, b in seen) or "none") + "."
    lookalikes = [f"{n} ({b})" for n, b in seen if LOOKALIKE_WORD in n.lower() and b != bundle_id]
    if lookalikes:
        line += f" Named like this app but with another bundle id: {', '.join(lookalikes)}."
    return line


# A new group offers its iOS builds to Apple silicon Macs and Vision Pro too. ForIT Dictate is an iPhone app, and
# an unasked-for Mac copy is noise (for-Squelch's remote landed in Ben's /Applications that way on 2026-10-06).
# Every run turns both off again.
PHONE_ONLY = {"iosBuildsAvailableForAppleSiliconMac": False, "iosBuildsAvailableForAppleVision": False}


def keep_on_phones(api: Api, group: dict) -> bool:
    """PATCH the group's Mac and Vision Pro availability off unless both already are. True if it patched."""
    attrs = group.get("attributes") or {}
    if all(attrs.get(k) is False for k in PHONE_ONLY):
        return False
    api("PATCH", f"/betaGroups/{group['id']}",
        body={"data": {"type": "betaGroups", "id": group["id"], "attributes": dict(PHONE_ONLY)}})
    return True


def github_output_lines(out: Resolved) -> list[str]:
    return [
        f"ready={'true' if out.ready else 'false'}",
        f"app_id={out.app_id or ''}",
        f"group_id={out.group_id or ''}",
    ]


def report(out: Resolved, require: bool) -> tuple[str, int]:
    """The one line to print and the exit code. Before the upload a missing record
    is expected (notice, 0); after it, the upload was supposed to create it (error, 1)."""
    if out.ready:
        return f"App Store Connect app {out.app_id}; TestFlight group {out.group_id}.", 0
    if require:
        return f"::error title=App Store Connect app record missing::{out.reason}", 1
    return f"::notice title=App Store Connect app record not created yet::{out.reason}", 0


def make_api(key_id: str, issuer_id: str, private_key: str) -> Api:
    import jwt  # pyjwt — on the Mini's python3 (pip3 install --user pyjwt cryptography), never needed by the tests

    def mint_token() -> str:
        now = int(time.time())
        return jwt.encode(
            {"iss": issuer_id, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
            private_key, algorithm="ES256", headers={"kid": key_id, "typ": "JWT"},
        )

    def api(method: str, path: str, body: Optional[dict] = None) -> dict:
        headers = {"Authorization": f"Bearer {mint_token()}"}
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(ASC_BASE + path, method=method, data=data, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                raw = resp.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")[:500]
            raise AscError(f"App Store Connect {method} {path} -> HTTP {e.code}: {detail}",
                           status=e.code, detail=detail)

    return api


def main(argv: Optional[list[str]] = None) -> int:
    import argparse
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--require", action="store_true",
                    help="fail when the app record is missing (run this way after the upload)")
    args = ap.parse_args(argv)
    key_id = os.environ["ASC_KEY_ID"]
    issuer_id = os.environ["ASC_ISSUER_ID"]
    private_key = base64.b64decode(os.environ["ASC_KEY_BASE64"]).decode()
    bundle_id = os.environ["BUNDLE_ID"]
    group_name = os.environ.get("BETA_GROUP_NAME", "ForIT internal")
    out = resolve(make_api(key_id, issuer_id, private_key), bundle_id, group_name)
    line, code = report(out, require=args.require)
    print(line)
    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a") as f:
            f.write("\n".join(github_output_lines(out)) + "\n")
    return code


if __name__ == "__main__":
    sys.exit(main())

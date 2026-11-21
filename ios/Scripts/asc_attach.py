#!/usr/bin/env python3
# Ported from for-Notes apps/ios/Scripts at 6c199f5; names adapted to ForIT Dictate, logic unchanged.
"""After the upload, wait for App Store Connect to finish processing it and make
it visible to the TestFlight beta group.

The upload alone does NOT make a build visible to testers: a beta group with
hasAccessToAllBuilds=false only sees builds explicitly attached through the API
(forit-Productivity-iOS build 17 shipped invisible until this existed). An internal
group WITH access to all builds — ForIT internal, the group asc_resolve.py creates —
already sees every build the moment processing finishes, and App Store Connect
refuses the attach for such a group with HTTP 422 "Builds cannot be assigned to this
internal group" (run 33999841100, both platforms). So the group is looked up first
and the attach is skipped when there is nothing to attach.

The lookup is filtered by platform: for-Calendar's iOS and Mac jobs uploaded the SAME
CFBundleVersion in one run, and without the filter the iOS step could attach the Mac
build. ForIT Dictate ships the iPhone build (IOS) only; the filter stays so a second
platform built from the same run can never be picked up by the iPhone job.

An upload Apple refuses never becomes a build at all: it is not listed, however long
the wait, and the reason is only on the upload itself (ForIT Notes build 59, IOS,
2026-11-10: error 90626 on an App Intent description, and the job ended green after a
20-minute wait with "attach manually"). So while the build is not listed the upload's
own state is read too, and a FAILED one ends the step red at once with Apple's errors,
with or without --require-valid.

--require-valid makes a build that is not VALID in time a red step instead of a
warning, and prints the VALID build's internal TestFlight state
(buildBetaDetail.internalBuildState, IN_BETA_TESTING once internal testers have it).

This also sets the build's "What to Test" text (--whats-new) once it is VALID, so the
testers see what to try. ForIT Dictate is internal testing only: no external group, no
public link, no Beta App Review. Scripts/mini-testflight.sh runs this after its upload.
(Ported from for-LMS apps/ios/Scripts, itself from for-Messages, for-CRM, for-Calendar
and for-Squelch; logic unchanged.)

Pure logic takes an injected `api` callable and clock (Scripts/test_asc_attach.py).

Usage (env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_BASE64):
  asc_attach.py --app-id <id> --group-id <id> --version <CFBundleVersion> --platform IOS|VISION_OS|MAC_OS
                [--whats-new "<text>"] [--require-valid]
"""
from __future__ import annotations

import argparse
import base64
import os
import sys
import time
from typing import Callable, Optional

import asc_resolve

Api = Callable[..., dict]
LOCALE = "en-US"


class UploadRefused(Exception):
    """Apple refused the upload: there is no build and there will not be one."""

    def __init__(self, errors: list[str]):
        super().__init__("; ".join(errors))
        self.errors = errors


def refused_upload(api: Api, app_id: str, version: str, platform: str) -> Optional[list[str]]:
    """Apple's errors when the newest upload of this version on this platform is FAILED,
    else None. Never raises: an upload list that cannot be read changes nothing about
    the wait for the build."""
    try:
        rows = api("GET", f"/apps/{app_id}/buildUploads?limit=20&sort=-uploadedDate").get("data", [])
    except asc_resolve.AscError:
        return None
    for row in rows:
        attrs = row.get("attributes") or {}
        if str(attrs.get("cfBundleVersion")) != str(version) or attrs.get("platform") != platform:
            continue
        state = attrs.get("state") or {}
        if state.get("state") != "FAILED":
            return None
        errors = [" ".join(str(part) for part in (e.get("code"), e.get("description")) if part)
                  for e in state.get("errors") or [] if isinstance(e, dict)]
        return [e for e in errors if e] or ["no reason given"]
    return None


def wait_for_build(api: Api, app_id: str, version: str, platform: str, *,
                   now: Callable[[], float], sleep: Callable[[float], None],
                   poll: float = 30, timeout: float = 1200) -> Optional[str]:
    """The id of the VALID build for this version on this platform, or None when the
    build is INVALID or not processed before the deadline. Raises UploadRefused when
    the build is not listed and Apple has marked its upload FAILED."""
    deadline = now() + timeout
    path = (f"/builds?filter[app]={app_id}&filter[version]={version}"
            f"&filter[preReleaseVersion.platform]={platform}&sort=-uploadedDate")
    while True:
        builds = api("GET", path).get("data", [])
        if builds:
            b = builds[0]
            state = b["attributes"]["processingState"]
            print(f"found build {b['id']} version={version} platform={platform} state={state}")
            if state == "VALID":
                return b["id"]
            if state == "INVALID":
                print("::warning::build INVALID — not attaching to TestFlight group")
                return None
        else:
            refused = refused_upload(api, app_id, version, platform)
            if refused:
                raise UploadRefused(refused)
            print(f"build version={version} platform={platform} not visible in ASC yet, waiting...")
        if now() + poll >= deadline:
            return None
        sleep(poll)


def group_sees_all_builds(api: Api, group_id: str) -> bool:
    """True for an internal group with access to all builds: every build is visible to
    it already, and App Store Connect refuses the attach POST for it (422)."""
    attrs = api("GET", f"/betaGroups/{group_id}").get("data", {}).get("attributes", {})
    return bool(attrs.get("isInternalGroup") and attrs.get("hasAccessToAllBuilds"))


def attach(api: Api, group_id: str, build_id: str) -> str:
    """Make the build visible to the group. Returns the line to print."""
    if group_sees_all_builds(api, group_id):
        return (f"beta group {group_id} is an internal group with access to all builds — "
                f"build {build_id} is visible to it already; nothing to attach")
    api("POST", f"/betaGroups/{group_id}/relationships/builds",
        body={"data": [{"type": "builds", "id": build_id}]})
    return f"attached build {build_id} to beta group {group_id}"


def ensure_whats_new(api: Api, build_id: str, whats_new: str) -> str:
    """The build's "What to Test" (its en-US beta build localization). Idempotent."""
    rows = api("GET", f"/builds/{build_id}/betaBuildLocalizations").get("data", [])
    current = next((r for r in rows if r["attributes"].get("locale") == LOCALE), None)
    if current is None:
        api("POST", "/betaBuildLocalizations", body={"data": {
            "type": "betaBuildLocalizations",
            "attributes": {"locale": LOCALE, "whatsNew": whats_new},
            "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
        }})
        return "set what to test on the build"
    if current["attributes"].get("whatsNew") == whats_new:
        return "what to test already set on the build"
    api("PATCH", f"/betaBuildLocalizations/{current['id']}", body={"data": {
        "type": "betaBuildLocalizations", "id": current["id"], "attributes": {"whatsNew": whats_new},
    }})
    return "updated what to test on the build"


def internal_state(api: Api, build_id: str) -> str:
    """The build's internal TestFlight state, e.g. IN_BETA_TESTING."""
    attrs = api("GET", f"/builds/{build_id}/buildBetaDetail").get("data", {}).get("attributes", {})
    return attrs.get("internalBuildState") or "unknown"


def run(api: Api, app_id: str, group_id: str, version: str, platform: str, *,
        now: Callable[[], float], sleep: Callable[[float], None], whats_new: str = "",
        require_valid: bool = False) -> int:
    try:
        build_id = wait_for_build(api, app_id, version, platform, now=now, sleep=sleep)
    except UploadRefused as refused:
        # Not a warning even without --require-valid: nothing was released and waiting will not change it.
        for error in refused.errors:
            print(f"::error title=Upload refused by Apple::build {version} ({platform}): {error}")
        return 1
    if not build_id:
        if require_valid:
            print(f"::error title=Build not VALID::build {version} ({platform}) is not VALID in App Store Connect")
            return 1
        print("::warning::could not attach build to TestFlight group (not VALID within timeout) — attach manually")
        return 0
    if whats_new.strip():
        try:
            print(ensure_whats_new(api, build_id, whats_new.strip()))
        except asc_resolve.AscError as e:
            # Testers can still install the build; only the text is missing.
            print(f"::warning::could not set What to Test on build {build_id} (HTTP {e.status}): {e.detail}")
    try:
        print(f"{attach(api, group_id, build_id)} (version={version}, {platform})")
    except asc_resolve.AscError as e:
        if e.status != 422:
            raise  # auth, transport, Apple outage: fail the step so someone looks
        # 422 is App Store Connect saying this link is not allowed for this group.
        # The build is not lost — it is in ASC, VALID — so warn and keep the run green.
        print(f"::warning::App Store Connect refused to attach build {build_id} to beta group "
              f"{group_id} (HTTP 422): {e.detail}")
    if require_valid:
        print(f"build {build_id} ({platform}) internal testing: {internal_state(api, build_id)}")
    return 0


def main(argv: Optional[list[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--app-id", required=True)
    ap.add_argument("--group-id", required=True)
    ap.add_argument("--version", required=True)
    ap.add_argument("--platform", required=True, choices=["IOS", "VISION_OS", "MAC_OS"])
    ap.add_argument("--whats-new", default="", help="the build's What to Test text (en-US)")
    ap.add_argument("--require-valid", action="store_true",
                    help="fail when the build is not VALID in time, and print its internal TestFlight state")
    args = ap.parse_args(argv)

    private_key = base64.b64decode(os.environ["ASC_KEY_BASE64"]).decode()
    api = asc_resolve.make_api(os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"], private_key)
    return run(api, args.app_id, args.group_id, args.version, args.platform, now=time.time, sleep=time.sleep,
               whats_new=args.whats_new, require_valid=args.require_valid)


if __name__ == "__main__":
    sys.exit(main())

# Ported from for-Notes apps/ios/Scripts at 6c199f5; names adapted to ForIT Dictate, logic unchanged.
"""Tests for Scripts/asc_resolve.py — the App Store Connect lookup that
Scripts/mini-testflight.sh runs before its upload. Pure logic against an injected
`api` callable; no network, no key material."""
import unittest

import asc_resolve

PHONE_ONLY = {"iosBuildsAvailableForAppleSiliconMac": False, "iosBuildsAvailableForAppleVision": False}
BUNDLE = "io.forit.dictate"


class FakeApi:
    def __init__(self, responses):
        self.responses = responses  # (method, path-prefix) -> body or Exception
        self.calls = []

    def __call__(self, method, path, body=None):
        self.calls.append((method, path, body))
        for (m, prefix), resp in self.responses.items():
            if m == method and path.startswith(prefix):
                if isinstance(resp, BaseException):  # AscError is a SystemExit
                    raise resp
                return resp
        raise AssertionError(f"unexpected call {method} {path}")


class ResolveTests(unittest.TestCase):
    def test_no_app_record_names_the_one_manual_step(self):
        api = FakeApi({
            ("GET", f"/apps?filter[bundleId]={BUNDLE}"): {"data": []},
            ("GET", "/apps?fields[apps]=name,bundleId"): {"data": []},
        })
        out = asc_resolve.resolve(api, BUNDLE, group_name="ForIT internal")
        self.assertFalse(out.ready)
        self.assertIsNone(out.app_id)
        self.assertIn(BUNDLE, out.reason)
        self.assertIn("New App", out.reason)
        self.assertIn('name "ForIT Dictate"', out.reason)
        self.assertIn("cannot create it", out.reason)
        self.assertIn("This API key sees 0 app(s): none.", out.reason)
        # Nothing is created when the app record is missing; the second GET only lists what the key sees.
        self.assertEqual([m for m, _, _ in api.calls], ["GET", "GET"])

    def test_missing_record_lists_the_apps_the_key_sees_and_flags_a_lookalike(self):
        api = FakeApi({
            ("GET", f"/apps?filter[bundleId]={BUNDLE}"): {"data": []},
            ("GET", "/apps?fields[apps]=name,bundleId"): {"data": [
                {"id": "1", "attributes": {"name": "ForIT Messages", "bundleId": "io.forit.messages"}},
                {"id": "2", "attributes": {"name": "ForIT Dictate", "bundleId": "io.forit.dictate.app"}},
            ]},
        })
        out = asc_resolve.resolve(api, BUNDLE, group_name="ForIT internal")
        self.assertFalse(out.ready)
        self.assertIn("This API key sees 2 app(s): ForIT Messages (io.forit.messages), "
                      "ForIT Dictate (io.forit.dictate.app).", out.reason)
        self.assertIn("Named like this app but with another bundle id: ForIT Dictate (io.forit.dictate.app).",
                      out.reason)

    def test_a_refused_app_listing_is_reported_not_raised(self):
        api = FakeApi({
            ("GET", f"/apps?filter[bundleId]={BUNDLE}"): {"data": []},
            ("GET", "/apps?fields[apps]=name,bundleId"): asc_resolve.AscError("forbidden", status=403, detail="{}"),
        })
        out = asc_resolve.resolve(api, BUNDLE, group_name="ForIT internal")
        self.assertFalse(out.ready)
        self.assertIn("Listing the apps this key sees failed too (HTTP 403).", out.reason)

    def test_report_before_upload_is_a_notice_after_upload_an_error(self):
        ready = asc_resolve.Resolved(ready=True, app_id="1", group_id="g", reason="")
        self.assertEqual(asc_resolve.report(ready, require=False)[1], 0)
        self.assertEqual(asc_resolve.report(ready, require=True)[1], 0)
        missing = asc_resolve.Resolved(ready=False, app_id=None, group_id=None, reason="no record for x")
        line, code = asc_resolve.report(missing, require=False)
        self.assertEqual(code, 0)
        self.assertTrue(line.startswith("::notice"), line)
        line, code = asc_resolve.report(missing, require=True)
        self.assertEqual(code, 1)
        self.assertTrue(line.startswith("::error"), line)
        self.assertIn("no record for x", line)

    def test_existing_app_and_internal_group_are_reused(self):
        api = FakeApi({
            ("GET", f"/apps?filter[bundleId]={BUNDLE}"): {"data": [{"id": "6740000001"}]},
            ("GET", "/betaGroups?filter[app]=6740000001"): {"data": [
                {"id": "ext-1", "attributes": {"isInternalGroup": False, "name": "External testers"}},
                {"id": "int-1", "attributes": {"isInternalGroup": True, "name": "Team", **PHONE_ONLY}},
            ]},
        })
        out = asc_resolve.resolve(api, BUNDLE, group_name="ForIT internal")
        self.assertTrue(out.ready)
        self.assertEqual(out.app_id, "6740000001")
        self.assertEqual(out.group_id, "int-1")
        self.assertEqual([m for m, _, _ in api.calls], ["GET", "GET"])

    def test_a_group_that_offers_builds_to_macs_is_patched_back_to_phones(self):
        api = FakeApi({
            ("GET", f"/apps?filter[bundleId]={BUNDLE}"): {"data": [{"id": "6740000002"}]},
            ("GET", "/betaGroups?filter[app]=6740000002"): {"data": [
                {"id": "int-1", "attributes": {"isInternalGroup": True, "iosBuildsAvailableForAppleSiliconMac": True,
                                               "iosBuildsAvailableForAppleVision": False}},
            ]},
            ("PATCH", "/betaGroups/int-1"): {"data": {"id": "int-1"}},
        })
        out = asc_resolve.resolve(api, BUNDLE, group_name="ForIT internal")
        self.assertEqual(out.group_id, "int-1")
        patch = [c for c in api.calls if c[0] == "PATCH"]
        self.assertEqual(len(patch), 1)
        self.assertEqual(patch[0][2]["data"]["attributes"], PHONE_ONLY)

    def test_first_group_is_used_when_no_internal_group_exists(self):
        api = FakeApi({
            ("GET", f"/apps?filter[bundleId]={BUNDLE}"): {"data": [{"id": "6740000001"}]},
            ("GET", "/betaGroups?filter[app]=6740000001"): {"data": [
                {"id": "ext-1", "attributes": {"isInternalGroup": False, "name": "External testers", **PHONE_ONLY}},
            ]},
        })
        out = asc_resolve.resolve(api, BUNDLE, group_name="ForIT internal")
        self.assertEqual(out.group_id, "ext-1")

    def test_missing_group_is_created_as_internal_with_access_to_all_builds(self):
        api = FakeApi({
            ("GET", f"/apps?filter[bundleId]={BUNDLE}"): {"data": [{"id": "6740000001"}]},
            ("GET", "/betaGroups?filter[app]=6740000001"): {"data": []},
            ("POST", "/betaGroups"): {"data": {"id": "new-1", "attributes": {
                "iosBuildsAvailableForAppleSiliconMac": True, "iosBuildsAvailableForAppleVision": True}}},
            ("PATCH", "/betaGroups/new-1"): {"data": {"id": "new-1"}},
        })
        out = asc_resolve.resolve(api, BUNDLE, group_name="ForIT internal")
        self.assertTrue(out.ready)
        self.assertEqual(out.group_id, "new-1")
        post = [c for c in api.calls if c[0] == "POST"][0]
        attrs = post[2]["data"]["attributes"]
        self.assertEqual(attrs["name"], "ForIT internal")
        self.assertTrue(attrs["isInternalGroup"])
        self.assertTrue(attrs["hasAccessToAllBuilds"])
        self.assertEqual(post[2]["data"]["relationships"]["app"]["data"], {"type": "apps", "id": "6740000001"})
        # A new group offers builds to Macs and Vision Pro; it is turned back to phones at once.
        self.assertEqual([c[2]["data"]["attributes"] for c in api.calls if c[0] == "PATCH"], [PHONE_ONLY])

    def test_github_output_lines(self):
        out = asc_resolve.Resolved(ready=True, app_id="1", group_id="g", reason="")
        self.assertEqual(asc_resolve.github_output_lines(out), ["ready=true", "app_id=1", "group_id=g"])
        out = asc_resolve.Resolved(ready=False, app_id=None, group_id=None, reason="x")
        self.assertEqual(asc_resolve.github_output_lines(out), ["ready=false", "app_id=", "group_id="])


class AscErrorTests(unittest.TestCase):
    def test_is_a_system_exit_that_carries_the_http_status_and_body(self):
        e = asc_resolve.AscError("App Store Connect POST /x -> HTTP 422: nope", status=422, detail="nope")
        self.assertIsInstance(e, SystemExit)  # uncaught: message on stderr, exit 1, as before
        self.assertEqual(e.code, "App Store Connect POST /x -> HTTP 422: nope")
        self.assertEqual((e.status, e.detail), (422, "nope"))


if __name__ == "__main__":
    unittest.main()

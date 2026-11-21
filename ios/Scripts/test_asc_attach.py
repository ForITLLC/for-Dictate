# Ported from for-Notes apps/ios/Scripts at 6c199f5; names adapted to ForIT Dictate, logic unchanged.
"""Tests for Scripts/asc_attach.py — after the upload, wait for App Store
Connect to finish processing it and attach it to the TestFlight group. Pure logic
against an injected `api` callable and an injected clock; no network, no sleeping."""
import contextlib
import io
import unittest

import asc_attach
import asc_resolve

APP_ID = "6740000001"  # a stand-in id; the ForIT Dictate record is found by bundle id


class SequenceApi:
    """Answers each GET from a queue (one response per poll); records every call.
    The list of uploads is not part of that queue: it answers `uploads` every time
    (none, unless a test says so), or raises `uploads_error`."""

    def __init__(self, get_responses, post_response=None, post_error=None, uploads=None, uploads_error=None):
        self.get_responses = list(get_responses)
        self.uploads = uploads or []
        self.uploads_error = uploads_error
        self.post_response = post_response or {}
        self.post_error = post_error  # raised by every POST when set (an AscError)
        self.calls = []

    def __call__(self, method, path, body=None):
        self.calls.append((method, path, body))
        if method == "GET" and "/buildUploads" in path:
            if self.uploads_error is not None:
                raise self.uploads_error
            return {"data": self.uploads}
        if method == "GET":
            return self.get_responses.pop(0) if self.get_responses else {"data": []}
        if self.post_error is not None:
            raise self.post_error
        return self.post_response


class FakeClock:
    def __init__(self):
        self.t = 1000.0
        self.slept = []

    def now(self):
        return self.t

    def sleep(self, s):
        self.slept.append(s)
        self.t += s


def build(bid, state):
    return {"id": bid, "attributes": {"processingState": state}}


def upload(version, platform, state, errors=()):
    return {"id": f"up-{version}-{platform}", "attributes": {
        "cfBundleVersion": version, "platform": platform, "uploadedDate": "2026-11-10T14:44:39-08:00",
        "state": {"state": state, "errors": [{"code": c, "description": d} for c, d in errors], "warnings": [], "infos": []},
    }}


SIRI = ("90626", 'Invalid Siri Support. App Intent description "Stops the recording on this Mac." cannot contain "mac"')


class RefusedUploadTests(unittest.TestCase):
    """ForIT Notes build 59 (IOS), 2026-11-10: Apple refused the upload, no build was ever
    listed, and the job waited 20 minutes and ended green."""

    def run_quiet(self, api, clock, **more):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = asc_attach.run(api, APP_ID, "group-1", "59", "IOS", now=clock.now, sleep=clock.sleep, **more)
        return code, out.getvalue()

    def test_a_refused_upload_fails_the_step_at_once_with_apples_reason(self):
        api = SequenceApi([], uploads=[upload("2", "IOS", "AWAITING_UPLOAD"), upload("59", "IOS", "FAILED", [SIRI]),
                                       upload("58", "MAC_OS", "COMPLETE")])
        clock = FakeClock()
        code, text = self.run_quiet(api, clock)
        self.assertEqual(code, 1)
        self.assertEqual(clock.slept, [])
        self.assertIn("::error title=Upload refused by Apple::build 59 (IOS): 90626 Invalid Siri Support.", text)
        self.assertIn('cannot contain "mac"', text)
        self.assertNotIn("attach manually", text)
        self.assertFalse(any(method != "GET" for method, _, _ in api.calls))

    def test_it_fails_without_require_valid_and_with_it(self):
        for require_valid in (False, True):
            api = SequenceApi([], uploads=[upload("59", "IOS", "FAILED", [SIRI])])
            code, _ = self.run_quiet(api, FakeClock(), require_valid=require_valid)
            self.assertEqual(code, 1)

    def test_the_uploads_are_asked_for_by_app_and_matched_on_version_and_platform(self):
        # The same build number refused on the Mac, or another number on the iPhone, is not this build.
        api = SequenceApi([{"data": []}, {"data": [build("b-59", "VALID")]}],
                          uploads=[upload("59", "MAC_OS", "FAILED", [SIRI]), upload("60", "IOS", "FAILED", [SIRI])])
        clock = FakeClock()
        self.assertEqual(asc_attach.wait_for_build(api, APP_ID, "59", "IOS", now=clock.now, sleep=clock.sleep), "b-59")
        asked = [path for _, path, _ in api.calls if "/buildUploads" in path]
        self.assertEqual(asked, [f"/apps/{APP_ID}/buildUploads?limit=20&sort=-uploadedDate"])

    def test_only_the_newest_upload_of_the_build_counts(self):
        # A refused try followed by a good upload of the same number is a build on its way.
        rows = [upload("59", "IOS", "PROCESSING"), upload("59", "IOS", "FAILED", [SIRI])]
        self.assertIsNone(asc_attach.refused_upload(SequenceApi([], uploads=rows), APP_ID, "59", "IOS"))
        self.assertEqual(asc_attach.refused_upload(SequenceApi([], uploads=rows[::-1]), APP_ID, "59", "IOS"), [" ".join(SIRI)])

    def test_an_upload_that_is_not_failed_changes_nothing(self):
        for state in ("AWAITING_UPLOAD", "PROCESSING", "COMPLETE"):
            self.assertIsNone(asc_attach.refused_upload(SequenceApi([], uploads=[upload("59", "IOS", state)]), APP_ID, "59", "IOS"))
        self.assertIsNone(asc_attach.refused_upload(SequenceApi([]), APP_ID, "59", "IOS"))

    def test_a_failed_upload_with_no_error_text_still_fails(self):
        self.assertEqual(asc_attach.refused_upload(SequenceApi([], uploads=[upload("59", "IOS", "FAILED")]), APP_ID, "59", "IOS"),
                         ["no reason given"])

    def test_an_upload_list_that_cannot_be_read_leaves_the_wait_as_it_was(self):
        api = SequenceApi([{"data": []}, {"data": [build("b-59", "VALID")]}],
                          uploads_error=asc_resolve.AscError("synthetic 403", status=403, detail="no access"))
        clock = FakeClock()
        self.assertEqual(asc_attach.wait_for_build(api, APP_ID, "59", "IOS", now=clock.now, sleep=clock.sleep), "b-59")
        self.assertEqual(clock.slept, [30])

    def test_a_listed_build_is_never_checked_against_the_uploads(self):
        api = SequenceApi([{"data": [build("b-59", "VALID")]}], uploads=[upload("59", "IOS", "FAILED", [SIRI])])
        clock = FakeClock()
        self.assertEqual(asc_attach.wait_for_build(api, APP_ID, "59", "IOS", now=clock.now, sleep=clock.sleep), "b-59")
        self.assertFalse(any("/buildUploads" in path for _, path, _ in api.calls))


class WaitForBuildTests(unittest.TestCase):
    def test_returns_the_valid_build_for_that_platform_only(self):
        api = SequenceApi([{"data": [build("B1", "VALID")]}])
        clock = FakeClock()
        found = asc_attach.wait_for_build(api, app_id=APP_ID, version="42", platform="IOS",
                                          now=clock.now, sleep=clock.sleep)
        self.assertEqual(found, "B1")
        path = api.calls[0][1]
        # for-Calendar's iOS and Mac jobs uploaded the same CFBundleVersion in one run; without the
        # platform filter the iOS step could attach the Mac build. ForIT Dictate is iOS only; the filter stays.
        self.assertIn("filter[preReleaseVersion.platform]=IOS", path)
        self.assertIn(f"filter[app]={APP_ID}", path)
        self.assertIn("filter[version]=42", path)
        self.assertEqual(clock.slept, [])

    def test_polls_until_processing_finishes(self):
        api = SequenceApi([{"data": []}, {"data": [build("B2", "PROCESSING")]}, {"data": [build("B2", "VALID")]}])
        clock = FakeClock()
        found = asc_attach.wait_for_build(api, app_id="A", version="7", platform="IOS",
                                          now=clock.now, sleep=clock.sleep, poll=30)
        self.assertEqual(found, "B2")
        self.assertEqual(clock.slept, [30, 30])

    def test_an_invalid_build_is_reported_as_none(self):
        api = SequenceApi([{"data": [build("B3", "INVALID")]}])
        clock = FakeClock()
        # Swallow the `::warning::build INVALID` line: printed to the CI log, GitHub renders
        # it as an annotation on the real release run and a fixture reads as a broken build.
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertIsNone(asc_attach.wait_for_build(api, app_id="A", version="7", platform="IOS",
                                                        now=clock.now, sleep=clock.sleep))

    def test_gives_up_at_the_deadline(self):
        api = SequenceApi([])  # never appears
        clock = FakeClock()
        found = asc_attach.wait_for_build(api, app_id="A", version="7", platform="IOS",
                                          now=clock.now, sleep=clock.sleep, poll=100, timeout=250)
        self.assertIsNone(found)
        polls = [c for c in api.calls if c[0] == "GET" and "/buildUploads" not in c[1]]
        self.assertEqual(len(polls), 3)  # t=0, 100, 200
        # While the build is not listed, each poll also reads the uploads.
        self.assertEqual(len(api.calls), 6)


def group(internal, all_builds):
    return {"data": {"id": "G1", "attributes": {"isInternalGroup": internal, "hasAccessToAllBuilds": all_builds}}}


class AttachTests(unittest.TestCase):
    def test_attach_posts_the_build_to_a_group_that_only_sees_attached_builds(self):
        api = SequenceApi([group(internal=False, all_builds=False)])
        line = asc_attach.attach(api, group_id="G1", build_id="B1")
        self.assertEqual(api.calls, [
            ("GET", "/betaGroups/G1", None),
            ("POST", "/betaGroups/G1/relationships/builds", {"data": [{"type": "builds", "id": "B1"}]}),
        ])
        self.assertIn("attached build B1", line)

    def test_attach_skips_an_internal_group_that_sees_all_builds(self):
        # ForIT internal: isInternalGroup + hasAccessToAllBuilds. Every build is visible
        # to it already and App Store Connect answers the POST with 422 "Builds cannot
        # be assigned to this internal group" (run 33999841100) — so no POST at all.
        api = SequenceApi([group(internal=True, all_builds=True)])
        line = asc_attach.attach(api, group_id="G1", build_id="B1")
        self.assertEqual([c[0] for c in api.calls], ["GET"])
        self.assertIn("nothing to attach", line)

    def test_an_internal_group_without_all_builds_access_still_gets_the_attach(self):
        api = SequenceApi([group(internal=True, all_builds=False)])
        asc_attach.attach(api, group_id="G1", build_id="B1")
        self.assertEqual([c[0] for c in api.calls], ["GET", "POST"])


class RunTests(unittest.TestCase):
    """`run` is what main() calls once the api exists: wait, attach, decide the exit code."""

    def run_with(self, api):
        clock = FakeClock()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = asc_attach.run(api, "A", "G1", "11", "IOS", now=clock.now, sleep=clock.sleep)
        return code, out.getvalue()

    def test_a_422_from_the_attach_is_a_warning_not_a_failure(self):
        api = SequenceApi([{"data": [build("B1", "VALID")]}, group(internal=False, all_builds=False)],
                          post_error=asc_resolve.AscError("POST -> HTTP 422", status=422,
                                                          detail="Cannot add internal group to a build."))
        code, out = self.run_with(api)
        self.assertEqual(code, 0)
        self.assertIn("::warning::", out)
        self.assertIn("Cannot add internal group to a build.", out)

    def test_any_other_http_error_still_fails_the_step(self):
        api = SequenceApi([{"data": [build("B1", "VALID")]}, group(internal=False, all_builds=False)],
                          post_error=asc_resolve.AscError("POST -> HTTP 401", status=401, detail="NOT_AUTHORIZED"))
        with self.assertRaises(asc_resolve.AscError) as ctx:
            self.run_with(api)
        self.assertEqual(ctx.exception.status, 401)

    def test_no_valid_build_in_time_is_a_warning_and_no_attach(self):
        api = SequenceApi([{"data": [build("B1", "INVALID")]}])
        code, out = self.run_with(api)
        self.assertEqual(code, 0)
        self.assertNotIn("POST", [c[0] for c in api.calls])
        self.assertIn("::warning::", out)


class RoutedApi:
    """Answers by (method, path prefix); records every call."""

    def __init__(self, routes):
        self.routes = routes
        self.calls = []

    def __call__(self, method, path, body=None):
        self.calls.append((method, path, body))
        for (m, prefix), resp in self.routes.items():
            if m == method and path.startswith(prefix):
                if isinstance(resp, BaseException):
                    raise resp
                return resp
        raise AssertionError(f"unexpected call {method} {path}")


class WhatsNewTests(unittest.TestCase):
    def test_sets_what_to_test_when_the_build_has_none(self):
        api = RoutedApi({("GET", "/builds/B1/betaBuildLocalizations"): {"data": []},
                         ("POST", "/betaBuildLocalizations"): {}})
        self.assertEqual(asc_attach.ensure_whats_new(api, "B1", "Open a course, then take its quiz."),
                         "set what to test on the build")
        body = api.calls[-1][2]["data"]
        self.assertEqual(body["attributes"], {"locale": "en-US", "whatsNew": "Open a course, then take its quiz."})
        self.assertEqual(body["relationships"]["build"]["data"]["id"], "B1")

    def test_leaves_the_same_text_alone_and_patches_a_different_one(self):
        row = {"id": "L1", "attributes": {"locale": "en-US", "whatsNew": "old"}}
        api = RoutedApi({("GET", "/builds/B1/betaBuildLocalizations"): {"data": [row]},
                         ("PATCH", "/betaBuildLocalizations/L1"): {}})
        self.assertEqual(asc_attach.ensure_whats_new(api, "B1", "old"), "what to test already set on the build")
        self.assertEqual(asc_attach.ensure_whats_new(api, "B1", "new"), "updated what to test on the build")
        self.assertEqual(api.calls[-1][2]["data"]["attributes"], {"whatsNew": "new"})

    def test_run_sets_it_after_the_build_is_valid_and_a_failure_is_only_a_warning(self):
        err = asc_resolve.AscError("no", status=409, detail="conflict")
        api = RoutedApi({("GET", "/builds?"): {"data": [build("B1", "VALID")]},
                         ("GET", "/builds/B1/betaBuildLocalizations"): {"data": []},
                         ("POST", "/betaBuildLocalizations"): err,
                         ("GET", "/betaGroups/G1"): {"data": {"attributes": {"isInternalGroup": True,
                                                                             "hasAccessToAllBuilds": True}}}})
        clock = FakeClock()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = asc_attach.run(api, "A1", "G1", "7", "IOS", now=clock.now, sleep=clock.sleep, whats_new="Try it.")
        self.assertEqual(rc, 0)
        self.assertIn("could not set What to Test", out.getvalue())
        self.assertIn("nothing to attach", out.getvalue())

    def test_no_text_no_call(self):
        api = RoutedApi({("GET", "/builds?"): {"data": [build("B1", "VALID")]},
                         ("GET", "/betaGroups/G1"): {"data": {"attributes": {"isInternalGroup": True,
                                                                             "hasAccessToAllBuilds": True}}}})
        clock = FakeClock()
        with contextlib.redirect_stdout(io.StringIO()):
            asc_attach.run(api, "A1", "G1", "7", "IOS", now=clock.now, sleep=clock.sleep)
        self.assertFalse(any("betaBuildLocalizations" in c[1] for c in api.calls))


class RequireValidTests(unittest.TestCase):
    """--require-valid: a build that is not VALID is a red step. mini-testflight.sh does not pass it today
    (iPhone only); the flag is kept for a second-platform job, which is why these use VISION_OS."""

    def run_with(self, api):
        clock = FakeClock()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = asc_attach.run(api, "A1", "G1", "7", "VISION_OS", now=clock.now, sleep=clock.sleep,
                                  require_valid=True)
        return code, out.getvalue()

    def test_an_invalid_build_fails_the_step(self):
        code, out = self.run_with(RoutedApi({("GET", "/builds?"): {"data": [build("B1", "INVALID")]}}))
        self.assertEqual(code, 1)
        self.assertIn("::error title=Build not VALID::", out)

    def test_a_valid_build_prints_its_internal_testing_state(self):
        api = RoutedApi({("GET", "/builds?"): {"data": [build("B1", "VALID")]},
                         ("GET", "/betaGroups/G1"): {"data": {"attributes": {"isInternalGroup": True,
                                                                             "hasAccessToAllBuilds": True}}},
                         ("GET", "/builds/B1/buildBetaDetail"): {"data": {"attributes": {
                             "internalBuildState": "IN_BETA_TESTING"}}}})
        code, out = self.run_with(api)
        self.assertEqual(code, 0)
        self.assertIn("filter[preReleaseVersion.platform]=VISION_OS", api.calls[0][1])
        self.assertIn("build B1 (VISION_OS) internal testing: IN_BETA_TESTING", out)

    def test_only_ios_and_visionos_can_be_asked_for(self):
        with self.assertRaises(SystemExit):
            asc_attach.main(["--app-id", "A", "--group-id", "G", "--version", "1", "--platform", "TV_OS"])


if __name__ == "__main__":
    unittest.main()

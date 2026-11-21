# Ported from for-Notes apps/ios/Scripts at 6c199f5; names adapted to ForIT Dictate, logic unchanged.
"""Tests for Scripts/asc_testers.py — put the people who should see TestFlight builds
into the beta group. Pure logic against an injected `api` callable."""
import unittest

import asc_testers


class FakeApi:
    """Exact-path fake: the tester lookups differ only by a trailing filter."""

    def __init__(self, responses):
        self.responses = responses  # (method, exact path) -> body or Exception
        self.calls = []

    def __call__(self, method, path, body=None):
        self.calls.append((method, path, body))
        resp = self.responses.get((method, path))
        if resp is None:
            raise AssertionError(f"unexpected call {method} {path}")
        if isinstance(resp, BaseException):  # AscError is a SystemExit
            raise resp
        return resp


IN_GROUP = "/betaTesters?filter[email]=b.thomas%40forit.io&filter[betaGroups]=g1"
BY_EMAIL = "/betaTesters?filter[email]=b.thomas%40forit.io"


class EnsureTesterTests(unittest.TestCase):
    def test_tester_already_in_group_is_left_alone(self):
        api = FakeApi({("GET", IN_GROUP): {"data": [{"id": "t1"}]}})
        self.assertEqual(asc_testers.ensure_tester(api, "g1", "b.thomas@forit.io"), "already in group")
        self.assertEqual([m for m, _, _ in api.calls], ["GET"])

    def test_known_tester_is_added_to_the_group(self):
        api = FakeApi({
            ("GET", IN_GROUP): {"data": []},
            ("GET", BY_EMAIL): {"data": [{"id": "t1"}]},
            ("POST", "/betaGroups/g1/relationships/betaTesters"): {},
        })
        self.assertEqual(asc_testers.ensure_tester(api, "g1", "b.thomas@forit.io"), "added to group")
        post = [c for c in api.calls if c[0] == "POST"][0]
        self.assertEqual(post[2], {"data": [{"type": "betaTesters", "id": "t1"}]})

    def test_unknown_tester_is_created_in_the_group(self):
        api = FakeApi({
            ("GET", IN_GROUP): {"data": []},
            ("GET", BY_EMAIL): {"data": []},
            ("POST", "/betaTesters"): {"data": {"id": "t2"}},
        })
        self.assertEqual(asc_testers.ensure_tester(api, "g1", "b.thomas@forit.io"), "created")
        post = [c for c in api.calls if c[0] == "POST"][0]
        data = post[2]["data"]
        self.assertEqual(data["type"], "betaTesters")
        self.assertEqual(data["attributes"], {"email": "b.thomas@forit.io"})
        self.assertEqual(data["relationships"]["betaGroups"]["data"], [{"type": "betaGroups", "id": "g1"}])

    def test_a_refused_link_creates_the_tester_again_with_the_group(self):
        refused = asc_testers.asc_resolve.AscError(
            'App Store Connect POST /betaGroups/g1/relationships/betaTesters -> HTTP 409: '
            '{"errors": [{"status": "409", "code": "STATE_ERROR", "title": "Tester(s) cannot be assigned"}]}',
            status=409, detail="STATE_ERROR")
        api = FakeApi({
            ("GET", IN_GROUP): {"data": []},
            ("GET", BY_EMAIL): {"data": [{"id": "t1"}]},
            ("POST", "/betaGroups/g1/relationships/betaTesters"): refused,
            ("GET", "/users?filter[username]=b.thomas%40forit.io"):
                {"data": [{"id": "u1", "attributes": {"firstName": "Ben", "lastName": "Thomas"}}]},
            ("POST", "/betaTesters"): {"data": {"id": "t3"}},
        })
        self.assertEqual(asc_testers.ensure_tester(api, "g1", "b.thomas@forit.io"), "created in group")
        data = api.calls[-1][2]["data"]
        self.assertEqual(data["attributes"], {"email": "b.thomas@forit.io", "firstName": "Ben", "lastName": "Thomas"})
        self.assertEqual(data["relationships"]["betaGroups"]["data"], [{"type": "betaGroups", "id": "g1"}])

    def test_any_other_link_error_is_raised(self):
        api = FakeApi({
            ("GET", IN_GROUP): {"data": []},
            ("GET", BY_EMAIL): {"data": [{"id": "t1"}]},
            ("POST", "/betaGroups/g1/relationships/betaTesters"): SystemExit("HTTP 500: boom"),
        })
        with self.assertRaises(SystemExit):
            asc_testers.ensure_tester(api, "g1", "b.thomas@forit.io")

    def test_emails_are_parsed_from_a_comma_or_space_separated_list(self):
        self.assertEqual(asc_testers.parse_emails("a@x.io, b@x.io  c@x.io,"), ["a@x.io", "b@x.io", "c@x.io"])
        self.assertEqual(asc_testers.parse_emails(""), [])


USER = "/users?filter[username]=me%40bthomas.io"
VISIBLE = "/users/u1/relationships/visibleApps?limit=200"
ADD_VISIBLE = "/users/u1/relationships/visibleApps"


class EnsureVisibleTests(unittest.TestCase):
    def per_app_user(self, visible):
        return {
            ("GET", USER): {"data": [{"id": "u1", "attributes": {"allAppsVisible": False}}]},
            ("GET", VISIBLE): {"data": visible},
            ("POST", ADD_VISIBLE): {},
        }

    def test_app_is_added_to_a_per_app_members_visible_apps(self):
        api = FakeApi(self.per_app_user([{"type": "apps", "id": "other"}]))
        self.assertEqual(asc_testers.ensure_visible(api, "app1", "me@bthomas.io"), "app made visible")
        self.assertEqual(api.calls[-1], ("POST", ADD_VISIBLE, {"data": [{"type": "apps", "id": "app1"}]}))

    def test_an_app_already_visible_is_left_alone(self):
        api = FakeApi(self.per_app_user([{"type": "apps", "id": "app1"}]))
        self.assertEqual(asc_testers.ensure_visible(api, "app1", "me@bthomas.io"), "app already visible")
        self.assertNotIn("POST", [c[0] for c in api.calls])

    def test_a_member_who_sees_all_apps_needs_nothing(self):
        api = FakeApi({("GET", USER): {"data": [{"id": "u1", "attributes": {"allAppsVisible": True}}]}})
        self.assertEqual(asc_testers.ensure_visible(api, "app1", "me@bthomas.io"), "sees all apps")
        self.assertEqual(len(api.calls), 1)

    def test_an_address_outside_the_team_is_skipped(self):
        api = FakeApi({("GET", USER): {"data": []}})
        self.assertEqual(asc_testers.ensure_visible(api, "app1", "me@bthomas.io"), "not a team member")


class FailureMessageTests(unittest.TestCase):
    def test_internal_group_refusal_names_the_manual_step(self):
        err = ('App Store Connect POST /betaGroups/g1/relationships/betaTesters -> HTTP 409: {\n'
               '  "errors" : [ { "code" : "STATE_ERROR", "detail" : "Tester(s) cannot be assigned" } ]\n}')
        msg = asc_testers.explain_failure("b.thomas@forit.io", err)
        self.assertTrue(msg.startswith("::warning title=TestFlight tester not added::b.thomas@forit.io: "))
        self.assertIn("Add Testers", msg)
        self.assertIn("visible apps", msg)  # a per-app Developer (me@bthomas.io) is only offered once the app is visible to them
        self.assertIn("ios/docs/SIGNING.md", msg)
        self.assertNotIn("\n", msg)

    def test_other_errors_are_reported_verbatim_on_one_line(self):
        msg = asc_testers.explain_failure("a@x.io", "HTTP 500: {\n  \"errors\" : [ ]\n}")
        self.assertEqual(msg, '::warning title=TestFlight tester not added::a@x.io: HTTP 500: { "errors" : [ ] }')


if __name__ == "__main__":
    unittest.main()

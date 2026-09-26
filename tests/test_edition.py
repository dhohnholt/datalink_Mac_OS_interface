"""The store edition must not do the things the sandbox forbids.

Each of these is a rejection if it ships wrong, and none of them fails at
build time, so they are asserted here instead.
"""

import unittest
from pathlib import Path
from unittest import mock

from datalink_scanner import edition, keychain, paper, ttess, updates


class SandboxDetectionTests(unittest.TestCase):
    def test_a_container_home_means_the_store_edition(self):
        # Measured on a signed sandboxed build, 2026-09-25.
        home = Path(
            "/Users/davidhohnholt/Library/Containers"
            "/org.davidhohnholt.datalink-scanner/Data"
        )
        with mock.patch.object(Path, "home", staticmethod(lambda: home)):
            self.assertTrue(edition.sandboxed())

    def test_an_ordinary_home_does_not(self):
        with mock.patch.object(
            Path, "home", staticmethod(lambda: Path("/Users/davidhohnholt"))
        ):
            self.assertFalse(edition.sandboxed())

    def test_this_test_run_is_not_sandboxed(self):
        # If this ever fails the rest of the suite is testing the wrong thing.
        self.assertFalse(edition.sandboxed())


class SandboxedBehaviourTests(unittest.TestCase):
    def setUp(self):
        for module in (updates, paper, keychain._edition):
            patch = mock.patch.object(module, "sandboxed", return_value=True) \
                if module is keychain._edition \
                else mock.patch.object(module.edition, "sandboxed", return_value=True)
            patch.start()
            self.addCleanup(patch.stop)

    def test_nothing_in_updates_will_run(self):
        # Two of these are forbidden outright: moving other applications to
        # the Trash, and editing the LaunchServices database.
        for call in (
            lambda: updates.latest_release(),
            lambda: updates.forget_stale_registrations(),
            lambda: updates.sweep([]),
            lambda: updates.upgrade(),
            lambda: updates.relaunch(Path("/nowhere")),
        ):
            with self.subTest(call=call):
                with self.assertRaises(updates.UpdateError):
                    call()

    def test_the_daily_check_is_off_and_cannot_be_turned_on(self):
        self.assertFalse(updates.auto_check_enabled(object()))
        self.assertFalse(updates.check_is_due(object()))

    def test_nothing_is_installed_at_runtime(self):
        # Downloading and running code is what App Review refuses most bluntly.
        self.assertFalse(paper.pip_available())
        with self.assertRaises(paper.PaperError):
            paper.install_packages()

    def test_it_does_not_claim_it_could_install_packages(self):
        # True here would be a claim the edition cannot make good on, even
        # though the button is hidden for a second reason.
        status = paper.status()
        self.assertFalse(status["can_install_packages"])

    def test_the_store_edition_ships_no_address(self):
        # The owner's endpoint is a default for his own Homebrew build. The
        # store edition must never use it, whatever is written in the module:
        # a stranger's reports cannot be aimed at somebody else's server.
        ttess.set_endpoint(None)
        self.addCleanup(ttess.set_endpoint, None)
        self.assertTrue(ttess.API_URL, "the owner's default went missing")
        self.assertEqual(ttess.api_url(), "")
        self.assertEqual(ttess.site_url(), "")
        self.assertEqual(ttess.review_base_url(), "")

    def test_nobody_s_site_is_written_into_anything_that_ships(self):
        # The ttess.py check above missed the markup: index.html carried the
        # site as the href of the Open link, so a store build shipped one
        # school's address in its own resources even though the module had
        # none. Check every file that goes into the bundle, not one of them.
        import re
        root = Path("src/datalink_scanner")
        host_of = re.compile(r"https?://([A-Za-z0-9.-]+)")
        # Placeholders and the app's own loopback are not somebody's site.
        allowed = {"example.org", "example.com", "localhost", "127.0.0.1"}
        documentation = ("github.com", "apple.com", "python.org")
        offenders = []
        # The page only. ttess.py holds the owner's default for his own
        # build, and the store edition refuses it at runtime instead.
        for path in sorted(root.glob("webui/*")):
            if not path.is_file() or path.suffix == ".pyc":
                continue
            real = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}$")
            for host in host_of.findall(path.read_text(errors="ignore")):
                # "https://.../where/a/human/reads/it" in the specification is
                # a placeholder, not a host.
                if not real.match(host) or host in allowed:
                    continue
                if any(host.endswith(d) for d in documentation):
                    continue
                offenders.append(f"{path.name}: {host}")
        self.assertEqual(offenders, [], "a real address is written into a shipped file")

    def test_it_ships_with_nobody_elses_address(self):
        # The Developer ID build was made for one school and carries that
        # school's address. Sending a stranger's student data there would be
        # wrong even if the server refused it.
        ttess.set_endpoint(None)
        self.addCleanup(ttess.set_endpoint, None)
        self.assertEqual(ttess.api_url(), "")
        self.assertEqual(ttess.site_url(), "")
        self.assertEqual(ttess.review_base_url(), "")

    def test_it_refuses_to_send_until_an_address_is_set(self):
        ttess.set_endpoint(None)
        self.addCleanup(ttess.set_endpoint, None)
        with self.assertRaises(ttess.UploadError) as caught:
            ttess.fetch_destinations("dlk_live_whatever")
        self.assertEqual(caught.exception.code, "no_endpoint")

    def test_the_teacher_can_point_it_at_their_own(self):
        self.addCleanup(ttess.set_endpoint, None)
        ttess.set_endpoint("https://example.org/datalink")
        self.assertEqual(ttess.api_url(), "https://example.org/datalink")

    def test_an_address_that_is_not_https_is_refused(self):
        # The token rides as a header on this request and the students ride in
        # the body.
        with self.assertRaises(ttess.UploadError) as caught:
            ttess._require_https("http://example.org/datalink")
        self.assertEqual(caught.exception.code, "insecure_url")

    def test_the_keychain_is_read_in_process(self):
        # Writing an executable out and running it is forbidden, and the
        # signature the helper works around is stable in this edition.
        self.assertEqual(keychain._through_helper("get", "s", "a"), (None, False))


class DeveloperIdBehaviourTests(unittest.TestCase):
    """The shipping edition must keep every one of those."""

    def test_updates_still_work_outside_the_sandbox(self):
        self.assertFalse(edition.sandboxed())
        # Not called for real -- only that the guard is not what stops them.
        with mock.patch.object(updates, "move_to_trash", side_effect=AssertionError):
            self.assertEqual(updates.sweep([]), [])
        self.assertTrue(updates.auto_check_enabled(_Store({})))


class _Store:
    def __init__(self, values):
        self.values = values

    def get_setting(self, key, default=None):
        return self.values.get(key, default)


if __name__ == "__main__":
    unittest.main()

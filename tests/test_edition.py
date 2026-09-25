"""The store edition must not do the things the sandbox forbids.

Each of these is a rejection if it ships wrong, and none of them fails at
build time, so they are asserted here instead.
"""

import unittest
from pathlib import Path
from unittest import mock

from datalink_scanner import edition, keychain, paper, updates


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

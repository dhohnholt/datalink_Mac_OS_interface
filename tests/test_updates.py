"""Tests for the update check, the sweep and the relaunch.

Nothing here touches the network, Homebrew, Spotlight or any real application
bundle. What matters is the judgement around those calls: which copy survives
a sweep, what is never touched, and that a failed step says so rather than
quietly leaving the user on an old version.
"""

import json
import plistlib
import subprocess
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

from datalink_scanner import updates


def make_bundle(root: Path, name: str = "DataLink Scanner.app", version="1.0.0",
                identifier=updates.BUNDLE_IDENTIFIER) -> Path:
    app = root / name
    (app / "Contents").mkdir(parents=True)
    (app / "Contents" / "Info.plist").write_bytes(
        plistlib.dumps(
            {"CFBundleIdentifier": identifier, "CFBundleShortVersionString": version}
        )
    )
    return app


class Reply:
    """The shape urlopen returns, as a context manager."""

    def __init__(self, payload):
        self._payload = json.dumps(payload).encode()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def read(self):
        return self._payload


class VersionTests(unittest.TestCase):
    def test_a_v_prefix_and_missing_parts_still_compare(self):
        self.assertEqual(updates.parse_version("v1.3.0"), (1, 3, 0))
        self.assertTrue(updates.is_newer("1.3", "1.2.9"))

    def test_ten_is_newer_than_nine(self):
        # String comparison would call 1.10.0 older than 1.9.0.
        self.assertTrue(updates.is_newer("1.10.0", "1.9.0"))
        self.assertFalse(updates.is_newer("1.9.0", "1.10.0"))

    def test_the_same_version_is_not_an_update(self):
        self.assertFalse(updates.is_newer("1.3.0", "1.3.0"))
        self.assertFalse(updates.is_newer("v1.3.0", "1.3.0"))

    def test_an_unreadable_version_never_prompts_an_update(self):
        self.assertFalse(updates.is_newer("", "1.3.0"))


class LatestReleaseTests(unittest.TestCase):
    def test_reads_the_tag_and_page(self):
        opener = mock.Mock(
            return_value=Reply({"tag_name": "v1.4.0", "html_url": "https://x/1.4.0"})
        )
        release = updates.latest_release(opener=opener)
        self.assertEqual(release["version"], "1.4.0")
        self.assertEqual(release["url"], "https://x/1.4.0")
        request = opener.call_args.args[0]
        self.assertTrue(request.full_url.startswith("https://"))

    def test_rate_limiting_is_explained_rather_than_shown_as_a_code(self):
        error = urllib.error.HTTPError("https://x", 403, "Forbidden", {}, None)
        with self.assertRaises(updates.UpdateError) as caught:
            updates.latest_release(opener=mock.Mock(side_effect=error))
        self.assertIn("rate-limiting", str(caught.exception))

    def test_being_offline_is_explained(self):
        error = urllib.error.URLError("No route to host")
        with self.assertRaises(updates.UpdateError) as caught:
            updates.latest_release(opener=mock.Mock(side_effect=error))
        self.assertIn("internet connection", str(caught.exception))

    def test_a_reply_without_a_tag_is_an_error_not_a_downgrade(self):
        with self.assertRaises(updates.UpdateError):
            updates.latest_release(opener=mock.Mock(return_value=Reply({})))

    def test_refuses_a_plain_http_update_source(self):
        with mock.patch.object(updates, "RELEASES_API", "http://example.test/latest"):
            with self.assertRaises(updates.UpdateError) as caught:
                updates.latest_release(opener=mock.Mock())
        self.assertIn("https", str(caught.exception))


class FindingCopiesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)

    def spotlight(self, *paths):
        return mock.Mock(
            return_value=subprocess.CompletedProcess(
                args=[], returncode=0, stdout="\n".join(str(path) for path in paths)
            )
        )

    def test_finds_what_spotlight_reports(self):
        first = make_bundle(self.root / "one")
        second = make_bundle(self.root / "two")
        found = updates.installed_copies(
            runner=self.spotlight(first, second), roots=()
        )
        self.assertEqual(found, sorted([first, second], key=lambda p: str(p).lower()))

    def test_ignores_another_application_with_a_stale_index_entry(self):
        ours = make_bundle(self.root / "ours")
        theirs = make_bundle(
            self.root / "theirs", name="Other.app", identifier="com.example.other"
        )
        found = updates.installed_copies(
            runner=self.spotlight(ours, theirs), roots=()
        )
        self.assertEqual(found, [ours])

    def test_a_missing_spotlight_does_not_stop_the_search(self):
        expected = make_bundle(self.root)
        runner = mock.Mock(side_effect=OSError("mdfind is gone"))
        found = updates.installed_copies(runner=runner, roots=(str(self.root),))
        self.assertEqual(found, [expected])

    def test_the_running_bundle_is_the_app_a_file_sits_inside(self):
        app = make_bundle(self.root)
        binary = app / "Contents" / "MacOS" / "python-runtime"
        binary.parent.mkdir(parents=True)
        binary.write_text("")
        self.assertEqual(updates.running_bundle(binary), app.resolve())

    def test_no_bundle_when_running_from_a_plain_interpreter(self):
        self.assertIsNone(updates.running_bundle(self.root / "bin" / "python3"))


class KeeperTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)
        patch = mock.patch.object(updates, "homebrew_bundle", return_value=None)
        patch.start()
        self.addCleanup(patch.stop)

    def test_homebrews_copy_wins_even_against_a_newer_one(self):
        managed = make_bundle(self.root / "cellar", version="1.0.0")
        newer = make_bundle(self.root / "downloads", version="9.9.9")
        with mock.patch.object(updates, "homebrew_bundle", return_value=managed):
            # A newer copy elsewhere goes stale the next time the formula
            # moves, so the managed one is the one worth keeping.
            self.assertEqual(updates.choose_keeper([managed, newer]), managed)

    def test_otherwise_the_highest_version_wins(self):
        old = make_bundle(self.root / "old", version="1.2.2")
        new = make_bundle(self.root / "new", version="1.3.0")
        self.assertEqual(updates.choose_keeper([old, new]), new)

    def test_duplicates_are_everything_but_the_keeper(self):
        keeper = make_bundle(self.root / "keep", version="1.3.0")
        extra = make_bundle(self.root / "build", version="0.0.0")
        self.assertEqual(updates.duplicates([keeper, extra], keeper), [extra])

    def test_a_symlink_onto_the_keeper_is_not_a_duplicate(self):
        keeper = make_bundle(self.root / "cellar", version="1.3.0")
        link = self.root / "DataLink Scanner.app"
        link.symlink_to(keeper)
        # /Applications normally holds exactly this: a link onto the copy
        # Homebrew manages. Trashing it would unlink the app from the Dock.
        self.assertEqual(updates.duplicates([link, keeper], keeper), [])

    def test_homebrews_own_storage_is_never_swept(self):
        keeper = make_bundle(self.root / "keep", version="1.3.0")
        cellar = make_bundle(self.root / "Cellar" / "datalink-scanner" / "1.2.2")
        # `brew cleanup` owns those; moving one breaks Homebrew's records.
        self.assertEqual(updates.duplicates([keeper, cellar], keeper), [])

    def test_nothing_is_swept_when_there_is_no_keeper(self):
        extra = make_bundle(self.root / "build")
        self.assertEqual(updates.duplicates([extra], None), [])


class SweepTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)
        home = self.root / "home"
        (home / ".Trash").mkdir(parents=True)
        patch = mock.patch("pathlib.Path.home", return_value=home)
        patch.start()
        self.addCleanup(patch.stop)
        self.trash = home / ".Trash"

    def test_copies_are_moved_to_the_trash_not_deleted(self):
        extra = make_bundle(self.root / "build")
        moved = updates.sweep([extra])
        self.assertFalse(extra.exists())
        self.assertEqual(len(moved), 1)
        self.assertTrue(moved[0].exists())
        self.assertEqual(moved[0].parent, self.trash)
        self.assertIn("older copy", moved[0].name)

    def test_two_copies_of_the_same_name_do_not_collide(self):
        first = make_bundle(self.root / "one")
        second = make_bundle(self.root / "two")
        moved = updates.sweep([first, second])
        self.assertEqual(len({path.name for path in moved}), 2)

    def test_a_copy_that_cannot_be_moved_does_not_abandon_the_rest(self):
        movable = make_bundle(self.root / "movable")
        missing = self.root / "gone" / "DataLink Scanner.app"
        moved = updates.sweep([missing, movable])
        self.assertEqual([path.name for path in moved][0].startswith("DataLink"), True)
        self.assertEqual(len(moved), 1)
        self.assertFalse(movable.exists())


class UpgradeTests(unittest.TestCase):
    def setUp(self):
        patch = mock.patch.object(updates, "brew_path", return_value="/opt/brew")
        patch.start()
        self.addCleanup(patch.stop)

    def runner(self, *results):
        return mock.Mock(
            side_effect=[
                subprocess.CompletedProcess(args=[], returncode=code, stdout=out, stderr="")
                for code, out in results
            ]
        )

    def test_runs_update_upgrade_and_cleanup_without_asking_anything(self):
        runner = self.runner((0, "updated"), (0, "upgraded"), (0, "cleaned"))
        updates.upgrade(runner=runner)
        commands = [call.args[0] for call in runner.call_args_list]
        self.assertEqual([command[1] for command in commands],
                         ["update", "upgrade", "cleanup"])
        # Homebrew 7 asks for confirmation, and no one is there to answer it.
        self.assertIn("--yes", commands[1])
        for call in runner.call_args_list:
            self.assertEqual(call.kwargs["stdin"], subprocess.DEVNULL)

    def test_a_failed_upgrade_reports_what_homebrew_said(self):
        runner = self.runner((0, "updated"), (1, "Error: no such formula"))
        with self.assertRaises(updates.UpdateError) as caught:
            updates.upgrade(runner=runner)
        self.assertIn("no such formula", str(caught.exception))

    def test_a_failed_cleanup_does_not_sink_a_good_upgrade(self):
        runner = self.runner((0, "updated"), (0, "upgraded"), (1, "could not remove"))
        updates.upgrade(runner=runner)

    def test_a_hung_homebrew_is_stopped_and_explained(self):
        runner = mock.Mock(side_effect=subprocess.TimeoutExpired("brew", 900))
        with self.assertRaises(updates.UpdateError) as caught:
            updates.upgrade(runner=runner)
        self.assertIn("still running", str(caught.exception))

    def test_without_homebrew_the_download_page_is_offered(self):
        with mock.patch.object(updates, "brew_path", return_value=None):
            with self.assertRaises(updates.UpdateError) as caught:
                updates.upgrade()
        self.assertIn(updates.RELEASES_PAGE, str(caught.exception))


class RelaunchTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)

    def test_waits_for_this_process_before_reopening(self):
        app = make_bundle(self.root)
        command = updates.relaunch_command(app, 4242)
        script = command[-1]
        self.assertIn("kill -0 4242", script)
        self.assertIn("/usr/bin/open", script)
        self.assertIn(str(app), script)

    def test_a_space_in_the_path_survives_the_shell(self):
        app = make_bundle(self.root / "my apps")
        script = updates.relaunch_command(app, 1)[-1]
        self.assertIn(f"'{app}'", script)

    def test_the_helper_outlives_the_app_that_spawned_it(self):
        spawn = mock.Mock()
        updates.relaunch(self.root / "DataLink Scanner.app", pid=7, spawn=spawn)
        self.assertTrue(spawn.call_args.kwargs["start_new_session"])

    def test_reopens_the_running_copy_when_there_is_nothing_else(self):
        running = make_bundle(self.root)
        self.assertEqual(updates.relaunch_target(None, running), running)

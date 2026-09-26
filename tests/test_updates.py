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


class StaleRegistrationTests(unittest.TestCase):
    """macOS keeps listing app copies after Homebrew deletes the keg.

    Launchpad and Spotlight read that list, so old versions show up as
    duplicates pointing at nothing. Fourteen had collected before anyone
    noticed.
    """

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.real = Path(self.temporary.name) / updates.APP_BUNDLE_NAME
        self.real.mkdir()
        self.gone = Path(self.temporary.name) / "old" / updates.APP_BUNDLE_NAME
        self.calls = []

    def dump(self, *paths):
        body = "\n".join(f"\tpath:      {path} (0x7c18)" for path in paths)

        def runner(command, **kwargs):
            self.calls.append(command)
            if command[1:] == ["-dump"]:
                return subprocess.CompletedProcess(command, 0, body, "")
            return subprocess.CompletedProcess(command, 0, "", "")

        return runner

    def test_a_copy_that_is_gone_is_listed(self):
        with mock.patch.object(Path, "is_file", return_value=True):
            stale = updates.stale_registrations(self.dump(self.gone))
        self.assertEqual(stale, [self.gone])

    def test_a_copy_that_is_still_there_is_left_alone(self):
        # It is a real duplicate, and belongs to the Trash sweep instead.
        with mock.patch.object(Path, "is_file", return_value=True):
            stale = updates.stale_registrations(self.dump(self.real))
        self.assertEqual(stale, [])

    def test_a_copy_in_the_trash_is_forgotten_even_though_it_exists(self):
        # The sweep puts duplicates in the Trash, which does not unregister
        # them — so tidying up left the duplicate in Launchpad regardless.
        trashed = Path.home() / ".Trash" / updates.APP_BUNDLE_NAME
        with mock.patch.object(Path, "is_file", return_value=True):
            stale = updates.stale_registrations(self.dump(trashed))
        self.assertEqual(stale, [trashed])

    def test_a_trash_on_another_volume_counts_too(self):
        trashed = Path("/Volumes/Backup/.Trashes/501") / updates.APP_BUNDLE_NAME
        with mock.patch.object(Path, "is_file", return_value=True):
            stale = updates.stale_registrations(self.dump(trashed))
        self.assertEqual(stale, [trashed])

    def test_a_folder_merely_named_like_the_trash_is_not_one(self):
        # "Trashed drafts" is somebody's folder, not a Trash.
        kept = Path(self.temporary.name) / "Trashed drafts" / updates.APP_BUNDLE_NAME
        kept.parent.mkdir(parents=True)
        kept.mkdir()
        with mock.patch.object(Path, "is_file", return_value=True):
            stale = updates.stale_registrations(self.dump(kept))
        self.assertEqual(stale, [])

    def test_in_trash_recognises_both_layouts(self):
        self.assertTrue(updates.in_trash(Path.home() / ".Trash" / "X.app"))
        self.assertTrue(updates.in_trash(Path("/Volumes/D/.Trashes/501/X.app")))
        self.assertFalse(updates.in_trash(Path("/Applications/X.app")))

    def test_other_applications_are_not_touched(self):
        with mock.patch.object(Path, "is_file", return_value=True):
            stale = updates.stale_registrations(
                self.dump("/Applications/Some Other.app", self.gone)
            )
        self.assertEqual(stale, [self.gone])

    def test_the_same_path_listed_twice_is_forgotten_once(self):
        with mock.patch.object(Path, "is_file", return_value=True):
            stale = updates.stale_registrations(self.dump(self.gone, self.gone))
        self.assertEqual(stale, [self.gone])

    def test_forgetting_calls_lsregister_for_each(self):
        with mock.patch.object(Path, "is_file", return_value=True):
            forgotten = updates.forget_stale_registrations(self.dump(self.gone))
        self.assertEqual(forgotten, [self.gone])
        self.assertIn([updates.LSREGISTER, "-u", str(self.gone)], self.calls)

    def test_nothing_happens_without_lsregister(self):
        with mock.patch.object(Path, "is_file", return_value=False):
            self.assertEqual(updates.stale_registrations(self.dump(self.gone)), [])

    def test_a_failure_to_dump_is_not_fatal(self):
        def runner(command, **kwargs):
            raise OSError("no such tool")

        with mock.patch.object(Path, "is_file", return_value=True):
            self.assertEqual(updates.stale_registrations(runner), [])

    def test_the_trash_sweep_tidies_the_list_as_well(self):
        # Tidying the copies on disk without tidying what macOS lists leaves
        # the duplicates exactly where they are seen.
        with mock.patch.object(updates, "forget_stale_registrations") as forget:
            updates.sweep([])
        forget.assert_called_once()


class UpgradeTests(unittest.TestCase):
    def setUp(self):
        patch = mock.patch.object(updates, "brew_path", return_value="/opt/brew")
        patch.start()
        self.addCleanup(patch.stop)
        self.commands = []
        self.progress = []

    def runner(self, *results, announce=()):
        """Stand in for one brew command, with the lines it would print."""
        replies = list(results)

        def run(command, env, on_line, timeout):
            self.commands.append((command, env))
            code, output = replies.pop(0)
            for line in announce:
                on_line(line)
            return code, output

        return run

    def upgrade(self, runner):
        return updates.upgrade(
            on_progress=lambda fraction, message: self.progress.append((fraction, message)),
            runner=runner,
        )

    def test_runs_update_upgrade_and_cleanup_without_asking_anything(self):
        self.upgrade(self.runner((0, "updated"), (0, "upgraded"), (0, "cleaned")))
        self.assertEqual(
            [command[1] for command, _env in self.commands],
            ["update", "upgrade", "cleanup"],
        )
        # Homebrew 7 asks for confirmation, and no one is there to answer it.
        self.assertIn("--yes", self.commands[1][0])
        for _command, env in self.commands:
            self.assertEqual(env["HOMEBREW_NO_AUTO_UPDATE"], "1")

    def test_progress_only_ever_moves_forward_and_ends_at_one(self):
        self.upgrade(
            self.runner(
                (0, ""), (0, ""), (0, ""),
                announce=["==> Downloading", "==> Pouring", "plain output"],
            )
        )
        fractions = [fraction for fraction, _message in self.progress]
        self.assertEqual(fractions, sorted(fractions))
        self.assertEqual(fractions[-1], 1.0)
        self.assertTrue(all(0.0 <= value <= 1.0 for value in fractions))

    def test_the_line_shown_is_homebrews_own_words(self):
        self.upgrade(self.runner((0, ""), (0, ""), (0, ""), announce=["==> Pouring datalink"]))
        self.assertIn("Pouring datalink", [message for _fraction, message in self.progress])

    def test_output_that_is_not_a_step_does_not_move_the_bar(self):
        self.upgrade(self.runner((0, ""), (0, ""), (0, ""), announce=["Already up-to-date."]))
        # One report per step plus the final one; nothing from the noise.
        self.assertEqual(len(self.progress), len(updates.UPGRADE_STEPS) + 1)

    def test_a_failed_upgrade_reports_what_homebrew_said(self):
        with self.assertRaises(updates.UpdateError) as caught:
            self.upgrade(self.runner((0, "updated"), (1, "Error: no such formula")))
        self.assertIn("no such formula", str(caught.exception))

    def test_a_failed_cleanup_does_not_sink_a_good_upgrade(self):
        self.upgrade(self.runner((0, "updated"), (0, "upgraded"), (1, "could not remove")))

    def test_a_hung_homebrew_is_stopped_and_explained(self):
        def run(command, env, on_line, timeout):
            raise updates.UpdateError("`upgrade` was still running after 15 minutes and was stopped.")

        with self.assertRaises(updates.UpdateError) as caught:
            self.upgrade(run)
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


class FakeStore:
    """Just the two settings calls the update preferences use."""

    def __init__(self, values=None):
        self.values = dict(values or {})

    def get_setting(self, key, default=""):
        return self.values.get(key, default)

    def set_setting(self, key, value):
        self.values[key] = value


class DailyCheckTests(unittest.TestCase):
    def setUp(self):
        self.store = FakeStore()

    def test_checking_is_on_until_it_is_turned_off(self):
        self.assertTrue(updates.auto_check_enabled(self.store))
        updates.set_auto_check(self.store, False)
        self.assertFalse(updates.auto_check_enabled(self.store))
        updates.set_auto_check(self.store, True)
        self.assertTrue(updates.auto_check_enabled(self.store))

    def test_the_first_launch_is_due(self):
        self.assertTrue(updates.check_is_due(self.store))

    def test_a_second_launch_the_same_day_is_not(self):
        updates.remember_check(self.store, now := 1_700_000_000.0)
        self.assertFalse(updates.check_is_due(self.store, now=now + 60))
        self.assertFalse(updates.check_is_due(self.store, now=now + 23 * 3600))

    def test_the_next_day_is_due_again(self):
        updates.remember_check(self.store, now := 1_700_000_000.0)
        self.assertTrue(updates.check_is_due(self.store, now=now + 24 * 3600))

    def test_turning_it_off_stops_the_check_outright(self):
        updates.set_auto_check(self.store, False)
        self.assertFalse(updates.check_is_due(self.store, now=2_000_000_000.0))

    def test_a_clock_that_moved_backwards_does_not_postpone_it_forever(self):
        # Restoring a machine, or correcting a wrong date, would otherwise
        # leave a check stamped in the future and never due again.
        updates.remember_check(self.store, 2_000_000_000.0)
        self.assertTrue(updates.check_is_due(self.store, now=1_700_000_000.0))

    def test_an_unreadable_timestamp_is_treated_as_never_checked(self):
        self.store.values[updates.LAST_CHECK_KEY] = "yesterday"
        self.assertEqual(updates.last_checked(self.store), 0.0)
        self.assertTrue(updates.check_is_due(self.store))


class DockTileTests(unittest.TestCase):
    """A tile dragged out of the keg points at a version the next upgrade
    deletes, and macOS then says the application cannot be opened."""

    def _dock(self, url):
        return plistlib.dumps({
            "persistent-apps": [
                {"tile-data": {"file-data": {
                    "_CFURLString": url, "_CFURLStringType": 15,
                    "_CFURLAliasData": b"stale-alias",
                }}}
            ]
        })

    def _runner(self, exported, record=None):
        def run(command, **kwargs):
            if command[:3] == ["/usr/bin/defaults", "export", "com.apple.dock"]:
                return subprocess.CompletedProcess(command, 0, stdout=exported)
            if record is not None:
                record.append(command)
            return subprocess.CompletedProcess(command, 0, stdout=b"")
        return run

    def test_a_tile_pointing_at_a_deleted_keg_is_stale(self):
        gone = "file:///opt/homebrew/Cellar/datalink-scanner/1.9.0/DataLink%20Scanner.app/"
        found = updates.stale_dock_entries(self._runner(self._dock(gone)))
        self.assertEqual(found, [gone])

    def test_a_tile_pointing_at_something_real_is_left_alone(self):
        here = "file://" + str(Path(__file__).parent).replace(" ", "%20") + "/DataLink%20Scanner.app/"
        Path(__file__).parent.joinpath("DataLink Scanner.app").mkdir(exist_ok=True)
        self.addCleanup(Path(__file__).parent.joinpath("DataLink Scanner.app").rmdir)
        self.assertEqual(updates.stale_dock_entries(self._runner(self._dock(here))), [])

    def test_the_applications_tile_is_never_touched(self):
        self.assertEqual(
            updates.stale_dock_entries(self._runner(self._dock(updates.STABLE_APP_URL))),
            [],
        )

    def test_repointing_writes_through_defaults_and_restarts_the_dock(self):
        # Never by writing the plist: the Dock holds its tiles in memory and
        # writes them back when it quits, which undoes a direct edit.
        gone = "file:///opt/homebrew/Cellar/datalink-scanner/1.9.0/DataLink%20Scanner.app/"
        commands = []
        replaced = updates.repoint_dock(self._runner(self._dock(gone), commands))
        self.assertEqual(replaced, [gone])
        self.assertIn(["/usr/bin/defaults", "import", "com.apple.dock", mock.ANY],
                      [c[:3] + [mock.ANY] for c in commands if c[:2] == ["/usr/bin/defaults", "import"]])
        self.assertIn(["/usr/bin/killall", "Dock"], commands)

    def test_the_store_edition_does_not_touch_the_dock(self):
        with mock.patch.object(updates.edition, "sandboxed", return_value=True):
            with self.assertRaises(updates.UpdateError):
                updates.repoint_dock()


class LaunchServicesRegistrationTests(unittest.TestCase):
    """The /Applications symlink is version-independent; the registration
    LaunchServices makes from it is not, because it resolves the link."""

    def test_linking_registers_the_stable_path(self):
        from datalink_scanner import cli

        calls = []

        def runner(command, **kwargs):
            calls.append(command)
            return subprocess.CompletedProcess(command, 0)

        app = Path("/Applications/DataLink Scanner.app")
        self.assertTrue(cli.register_with_launch_services(app, runner))
        self.assertEqual(calls, [[cli.LSREGISTER, "-f", str(app)]])

    def test_a_failure_to_register_is_not_fatal(self):
        from datalink_scanner import cli

        def runner(command, **kwargs):
            raise OSError("lsregister went missing")

        self.assertFalse(
            cli.register_with_launch_services(Path("/Applications/x.app"), runner)
        )

    def test_the_formula_does_not_touch_launch_services(self):
        # Refreshing the Launch Services record after an upgrade is the right
        # idea and a formula phase is the wrong place: that sandbox refuses
        # /Applications outright and makes lsregister fail even inside the
        # prefix. Both were tried and both failed. The formula's post_install
        # does something else entirely -- it reseals the bundle after
        # Homebrew's relocation -- and the app refreshes the record itself.
        formula = Path("packaging/homebrew/datalink-scanner.rb").read_text()
        self.assertNotIn("lsregister", formula)
        # The hook body only; caveats mentions /Applications legitimately.
        hook = formula[formula.index("def post_install") :]
        hook = hook[: hook.index("\n  end")]
        self.assertNotIn("/Applications", hook)

    def test_the_app_refreshes_the_record_at_startup(self):
        source = Path("src/datalink_scanner/app.py").read_text()
        self.assertIn("_refresh_launch_services_record", source)
        self.assertIn("register_with_launch_services", source)
        # Off the main thread, and never in the sandboxed edition.
        hook = source[source.index("def _refresh_launch_services_record") :]
        hook = hook[: hook.index("\n    def ")]
        self.assertIn("edition.sandboxed()", hook)
        self.assertIn("threading.Thread", hook)

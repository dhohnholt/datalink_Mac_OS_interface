"""Tests for how the connection token is stored.

Nothing here touches the real Keychain — a test that did would put a password
prompt on the screen of whoever ran it. What is checked is the machinery that
keeps macOS from asking: which binary gets copied, that it is built once, and
that the token reaches it down a pipe rather than on a command line.
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from datalink_scanner import keychain


class HelperLocationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        patch = mock.patch.dict(
            os.environ, {"DATALINK_KEYCHAIN_HELPER_DIR": self.temporary.name}
        )
        patch.start()
        self.addCleanup(patch.stop)

    def test_the_helper_lives_where_an_upgrade_cannot_move_it(self):
        helper = keychain.helper_path()
        self.assertEqual(helper.parent, Path(self.temporary.name))
        # The whole point: no version number anywhere in the path.
        self.assertNotIn("Cellar", str(helper))

    def test_a_frozen_build_has_no_helper_to_make(self):
        # Its sys.executable is the app itself, and it already lives at a path
        # the user chose, which does not move.
        with mock.patch.object(sys, "frozen", True, create=True):
            self.assertIsNone(keychain._interpreter())

    def test_the_real_binary_is_copied_rather_than_the_stub(self):
        # bin/python3.x re-execs the binary inside Python.app, and it is the
        # re-exec macOS records — copying the stub left the trust pointing at
        # the versioned framework, which was the original bug.
        source = keychain._interpreter()
        if source is None:
            self.skipTest("no interpreter to copy in this build")
        self.assertNotIn("/bin/python", str(source))

    def test_the_helper_is_built_once_and_then_reused(self):
        first = keychain.ensure_helper()
        if first is None:
            self.skipTest("no interpreter to copy in this build")
        stamped = first.stat().st_mtime_ns
        self.assertIsNotNone(keychain.ensure_helper())
        # Rebuilding would make a new file for the Keychain to be unsure about.
        self.assertEqual(first.stat().st_mtime_ns, stamped)

    def test_a_working_helper_is_kept_when_the_interpreter_changes(self):
        helper = keychain.ensure_helper()
        if helper is None:
            self.skipTest("no interpreter to copy in this build")
        stamp = helper.with_name(helper.name + ".source")
        was = helper.stat().st_ino
        stamp.write_text("a different interpreter entirely")
        keychain.ensure_helper()
        # Replacing the file is what costs a password prompt, so a Python
        # upgrade — or the app being run from another environment — must not
        # be reason enough to do it.
        self.assertEqual(helper.stat().st_ino, was)
        self.assertNotEqual(stamp.read_text(), "a different interpreter entirely")

    def test_a_broken_helper_is_repaired_when_it_is_used(self):
        helper = keychain.ensure_helper()
        if helper is None:
            self.skipTest("no interpreter to copy in this build")
        helper.write_text("not an interpreter")
        # Nothing checks the helper on the way past — it is trying to use it
        # that reveals the breakage, and one rebuild is earned there. Without
        # this the app would fall back to asking in-process for good.
        answered = keychain._ask_helper(
            {"action": "get", "service": "org.tmechs.datalink.nothing", "account": "x"}
        )
        self.assertEqual(answered, {"value": None})
        self.assertGreater(helper.stat().st_size, 1000)

    def test_a_rebuild_is_attempted_only_once(self):
        with mock.patch.object(keychain, "ensure_helper") as ensure:
            ensure.return_value = Path(self.temporary.name) / "missing-helper"
            with mock.patch.object(
                keychain.subprocess, "run", side_effect=OSError("still broken")
            ):
                self.assertIsNone(keychain._ask_helper({"action": "get"}))
        self.assertEqual([call.kwargs for call in ensure.call_args_list],
                         [{"rebuild": False}, {"rebuild": True}])

    def test_the_copy_does_not_depend_on_a_version_that_will_move(self):
        helper = keychain.ensure_helper()
        if helper is None:
            self.skipTest("no interpreter to copy in this build")
        listed = subprocess.run(
            ["/usr/bin/otool", "-L", str(helper)], capture_output=True, text=True
        )
        # A Cellar path carries the Python version in it, so the next patch
        # release deletes it and the helper dies with "Library missing" — after
        # which every call falls back to a password prompt.
        linked = [
            line.strip() for line in listed.stdout.splitlines()
            if "/Cellar/" in line
        ]
        self.assertEqual(linked, [], f"helper still pinned to {linked}")

    def test_the_copy_carries_its_own_signature(self):
        helper = keychain.ensure_helper()
        if helper is None:
            self.skipTest("no interpreter to copy in this build")
        # Without one, macOS refuses to record it as a trusted application at
        # all and the prompt comes back for good.
        checked = subprocess.run(
            ["/usr/bin/codesign", "-v", str(helper)], capture_output=True
        )
        self.assertEqual(checked.returncode, 0, checked.stderr.decode()[:200])


class HelperCallTests(unittest.TestCase):
    """The token must never become a command-line argument."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        helper = Path(self.temporary.name) / "keychain-helper"
        helper.write_text("#!/bin/sh\nexit 0\n")
        helper.chmod(0o755)
        self.helper = helper
        patch = mock.patch.object(keychain, "ensure_helper", return_value=helper)
        patch.start()
        self.addCleanup(patch.stop)

    def test_the_secret_travels_on_stdin_not_in_the_arguments(self):
        with mock.patch.object(keychain.subprocess, "run") as run:
            run.return_value = subprocess.CompletedProcess(
                args=[], returncode=0, stdout=json.dumps({"value": True}), stderr=""
            )
            keychain.set_password("svc", "acct", "dlk_live_secret")
        command = run.call_args.args[0]
        self.assertNotIn("dlk_live_secret", " ".join(command))
        self.assertIn("dlk_live_secret", run.call_args.kwargs["input"])

    def test_a_helper_that_cannot_run_falls_back_rather_than_failing(self):
        with mock.patch.object(keychain.subprocess, "run", side_effect=OSError("nope")):
            with mock.patch.object(keychain, "_get_here", return_value="fallback") as here:
                self.assertEqual(keychain.get_password("svc", "acct"), "fallback")
        here.assert_called_once()

    def test_a_helper_that_answers_nonsense_falls_back(self):
        with mock.patch.object(keychain.subprocess, "run") as run:
            run.return_value = subprocess.CompletedProcess(
                args=[], returncode=0, stdout="not json at all", stderr=""
            )
            with mock.patch.object(keychain, "_get_here", return_value="fallback"):
                self.assertEqual(keychain.get_password("svc", "acct"), "fallback")

    def test_a_keychain_failure_is_reported_rather_than_retried_in_process(self):
        # Asking again in-process would only put a second prompt on screen.
        with mock.patch.object(keychain.subprocess, "run") as run:
            run.return_value = subprocess.CompletedProcess(
                args=[], returncode=0,
                stdout=json.dumps({"error": "Keychain error -25293 while reading"}),
                stderr="",
            )
            with mock.patch.object(keychain, "_get_here") as here:
                with self.assertRaises(keychain.KeychainError):
                    keychain.get_password("svc", "acct")
        here.assert_not_called()

    def test_the_helper_can_be_turned_off(self):
        with mock.patch.dict(os.environ, {"DATALINK_KEYCHAIN_NO_HELPER": "1"}):
            with mock.patch.object(keychain, "_get_here", return_value="direct") as here:
                self.assertEqual(keychain.get_password("svc", "acct"), "direct")
        here.assert_called_once()


class HelperProtocolTests(unittest.TestCase):
    """The helper reads one request and writes one answer, both as JSON."""

    def serve(self, request, **patches):
        with mock.patch.object(keychain.sys, "stdin", mock.Mock(read=lambda: json.dumps(request))):
            written = []
            with mock.patch.object(keychain.sys, "stdout", mock.Mock(write=written.append)):
                with mock.patch.multiple(keychain, **patches):
                    keychain._serve()
        return json.loads("".join(written))

    def test_a_get_returns_the_value(self):
        answer = self.serve(
            {"action": "get", "service": "s", "account": "a"},
            _get_here=mock.Mock(return_value="dlk_live_x"),
        )
        self.assertEqual(answer, {"value": "dlk_live_x"})

    def test_a_set_passes_the_password_through(self):
        setter = mock.Mock()
        self.serve(
            {"action": "set", "service": "s", "account": "a", "password": "dlk_live_x"},
            _set_here=setter,
        )
        setter.assert_called_once_with("s", "a", "dlk_live_x")

    def test_a_delete_reports_whether_anything_went(self):
        answer = self.serve(
            {"action": "delete", "service": "s", "account": "a"},
            _delete_here=mock.Mock(return_value=True),
        )
        self.assertEqual(answer, {"value": True})

    def test_an_unknown_request_is_an_error_not_a_crash(self):
        self.assertIn(
            "error", self.serve({"action": "wat"}, _get_here=mock.Mock())
        )

    def test_a_keychain_error_comes_back_as_a_message(self):
        answer = self.serve(
            {"action": "get", "service": "s", "account": "a"},
            _get_here=mock.Mock(side_effect=keychain.KeychainError("cancelled")),
        )
        self.assertEqual(answer, {"error": "cancelled"})

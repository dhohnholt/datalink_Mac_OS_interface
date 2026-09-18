"""Tests for the local workspace server that need no scanner and no browser."""

import csv
import io
import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

from datalink_scanner import paths
from datalink_scanner.interface import DataLinkError
from datalink_scanner.store import Store
from datalink_scanner.server import (
    DataLinkRequestHandler,
    ScannerController,
    safe_export_filename,
)


class ExportFilenameTests(unittest.TestCase):
    def test_keeps_readable_names(self):
        self.assertEqual(safe_export_filename("Unit 1 Exam"), "Unit 1 Exam.csv")

    def test_does_not_double_the_extension(self):
        self.assertEqual(safe_export_filename("Unit 1.csv"), "Unit 1.csv")

    def test_falls_back_when_empty(self):
        self.assertEqual(safe_export_filename("   "), "datalink-session.csv")

    def test_strips_path_separators_and_quotes(self):
        # The name lands in a Content-Disposition header and in a filename,
        # so neither a traversal nor a header break may survive it.
        name = safe_export_filename('../../etc/passwd"')
        self.assertNotIn("/", name)
        self.assertNotIn('"', name)

    def test_replaces_non_ascii(self):
        self.assertEqual(safe_export_filename("Exam — 4º"), "Exam _ 4_.csv")


class SessionLifecycleTests(unittest.TestCase):
    """Starting and ending a session is now separate from the hardware."""

    def setUp(self):
        self._directory = tempfile.TemporaryDirectory()
        self.addCleanup(self._directory.cleanup)
        self.store = Store(":memory:")
        self.addCleanup(self.store.close)
        self.controller = ScannerController(Path(self._directory.name), self.store)

    def key_and_student(self):
        self.controller._record_scan({"number": 1, "role": "key", "received_at": "x",
                                      "answered_count": 3, "responses": ["A", "B", "C"]})
        self.controller._records.append({"number": 1, "role": "key", "received_at": "x",
                                         "answered_count": 3, "responses": ["A", "B", "C"]})
        self.controller._record_scan({"number": 2, "role": "student", "student_id": "900011",
                                      "received_at": "x", "answered_count": 3,
                                      "responses": ["A", "B", "D"]})
        self.controller._records.append({"number": 2, "role": "student", "student_id": "900011",
                                         "received_at": "x", "answered_count": 3,
                                         "responses": ["A", "B", "D"]})

    def test_a_fresh_controller_is_not_scanning(self):
        snapshot = self.controller.snapshot()
        self.assertFalse(snapshot["scanning"])
        self.assertIsNone(snapshot["session_id"])

    def test_starting_opens_a_session_with_its_own_log(self):
        self.store.set_setting("test_name", "Unit 1")
        session_id = self.controller.start_session(30)
        snapshot = self.controller.snapshot()
        self.assertTrue(snapshot["scanning"])
        self.assertEqual(snapshot["session_id"], session_id)
        self.assertEqual(snapshot["session_name"], "Unit 1")
        self.assertTrue(snapshot["output_path"].endswith(".jsonl"))

    def test_two_sessions_cannot_run_at_once(self):
        self.controller.start_session(30)
        with self.assertRaises(DataLinkError):
            self.controller.start_session(30)

    def test_ending_files_the_session_and_reports_what_it_held(self):
        self.store.set_setting("test_name", "Unit 1")
        session_id = self.controller.start_session(30)
        self.key_and_student()
        summary = self.controller.end_session()
        self.assertEqual(summary["session_id"], session_id)
        self.assertEqual(summary["sheets"], 1)
        self.assertIn("1 student sheet", summary["message"])
        self.assertIsNotNone(self.store.session(session_id)["ended_at"])
        self.assertFalse(self.controller.snapshot()["scanning"])

    def test_ending_without_a_session_says_so(self):
        with self.assertRaises(DataLinkError):
            self.controller.end_session()

    def test_the_next_session_starts_its_numbering_over(self):
        # Period 2 needs its own answer key, so sheet 1 has to be a key again.
        self.controller.start_session(30)
        self.key_and_student()
        self.controller.end_session()
        second = self.controller.start_session(30)
        self.assertEqual(self.controller.snapshot()["record_count"], 0)
        self.assertNotEqual(second, None)

    def test_a_session_with_sheets_survives_the_prune_on_ending(self):
        session_id = self.controller.start_session(30)
        self.key_and_student()
        self.controller.end_session()
        self.assertIsNotNone(self.store.session(session_id))

    def test_resetting_needs_a_connected_scanner(self):
        with self.assertRaises(DataLinkError):
            self.controller.reset_scanner()


class ExportCsvTests(unittest.TestCase):
    def setUp(self):
        self._directory = tempfile.TemporaryDirectory()
        self.addCleanup(self._directory.cleanup)
        self.store = Store(":memory:")
        self.addCleanup(self.store.close)
        self.controller = ScannerController(Path(self._directory.name), self.store)

    def test_header_covers_the_longest_record(self):
        self.controller.add_demo_record(30)
        rows = list(csv.reader(io.StringIO(self.controller.export_csv("P4").decode())))
        self.assertEqual(rows[0][-1], "Q30")
        self.assertEqual(rows[1][2], "P4")

    def test_empty_session_still_produces_a_header(self):
        rows = list(csv.reader(io.StringIO(self.controller.export_csv().decode())))
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0][0], "Scan")

    def test_rejects_out_of_range_question_count(self):
        for count in (0, 101, "abc"):
            with self.assertRaises(DataLinkError, msg=count):
                self.controller.add_demo_record(count)

    def test_accepts_any_count_in_range(self):
        self.controller.add_demo_record(64)
        rows = list(csv.reader(io.StringIO(self.controller.export_csv().decode())))
        self.assertEqual(rows[0][-1], "Q64")

    def test_first_sheet_is_the_answer_key(self):
        self.controller.add_demo_record(30)
        self.controller.add_demo_record(30)
        rows = list(csv.reader(io.StringIO(self.controller.export_csv().decode())))
        self.assertEqual([row[1] for row in rows[1:]], ["key", "student"])

    def test_clear_empties_the_session(self):
        self.controller.add_demo_record(30)
        self.controller.clear()
        self.assertEqual(self.controller.snapshot()["record_count"], 0)


class CaptureRootTests(unittest.TestCase):
    def test_explicit_directory_wins_over_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            resolved = paths.capture_root(directory)
            self.assertEqual(resolved, Path(directory).resolve())

    def test_environment_override(self):
        import os

        with tempfile.TemporaryDirectory() as directory:
            previous = os.environ.get("DATALINK_CAPTURE_DIR")
            os.environ["DATALINK_CAPTURE_DIR"] = directory
            try:
                self.assertEqual(paths.capture_root(), Path(directory).resolve())
            finally:
                if previous is None:
                    del os.environ["DATALINK_CAPTURE_DIR"]
                else:
                    os.environ["DATALINK_CAPTURE_DIR"] = previous

    def test_web_assets_are_installed_with_the_package(self):
        root = paths.web_root()
        for asset in ("index.html", "app.js", "styles.css"):
            self.assertTrue((root / asset).is_file(), f"missing {asset}")


class HttpApiTests(unittest.TestCase):
    """Drives the real handler over a real socket on an ephemeral port."""

    def setUp(self):
        self._directory = tempfile.TemporaryDirectory()
        self.addCleanup(self._directory.cleanup)
        self.store = Store(":memory:")
        self.addCleanup(self.store.close)
        DataLinkRequestHandler.controller = ScannerController(
            Path(self._directory.name), self.store
        )
        DataLinkRequestHandler.shutdown_requested = threading.Event()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), DataLinkRequestHandler)
        self.addCleanup(self.server.server_close)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.server.shutdown)
        self.base = "http://127.0.0.1:%d" % self.server.server_address[1]

    def post(self, path, payload):
        request = urllib.request.Request(
            self.base + path,
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=5) as response:
            return json.loads(response.read())

    def test_status_reports_a_disconnected_scanner(self):
        with urllib.request.urlopen(self.base + "/api/status", timeout=5) as response:
            snapshot = json.loads(response.read())
        self.assertEqual(snapshot["state"], "disconnected")
        self.assertEqual(snapshot["min_question_count"], 1)
        self.assertEqual(snapshot["max_question_count"], 100)

    def test_connect_requires_write_acknowledgement(self):
        # Connecting drives the scanner's mode; it must never happen implicitly.
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.post("/api/connect", {"port": "/dev/null", "question_count": 50})
        self.assertEqual(caught.exception.code, 400)
        self.assertIn("acknowledgement", json.loads(caught.exception.read())["error"])

    def test_a_session_starts_and_ends_over_the_api(self):
        # No scanner is attached, so this also proves the two are separate.
        started = self.post("/api/session/start", {"question_count": 30})
        self.assertTrue(started["scanning"])
        ended = self.post("/api/session/end", {})
        self.assertFalse(ended["scanning"])
        self.assertIn("message", ended["summary"])

    def test_resetting_without_a_scanner_is_refused(self):
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.post("/api/scanner/reset", {})
        self.assertEqual(caught.exception.code, 400)

    def test_index_is_served(self):
        with urllib.request.urlopen(self.base + "/", timeout=5) as response:
            body = response.read().decode()
        self.assertIn("Scanner workspace", body)

    def test_quit_signals_shutdown(self):
        self.assertTrue(self.post("/api/quit", {})["stopping"])
        self.assertTrue(DataLinkRequestHandler.shutdown_requested.wait(timeout=2))

    def get(self, path):
        with urllib.request.urlopen(self.base + path, timeout=5) as response:
            return json.loads(response.read())

    def test_classes_round_trip_through_the_api(self):
        payload = {"name": "Period 4", "students": [{"id": "900011", "name": "Ada"}]}
        self.assertEqual(self.post("/api/classes/save", payload)["classes"][0]["name"], "Period 4")
        self.assertEqual(len(self.get("/api/classes")["classes"][0]["students"]), 1)
        self.assertEqual(self.post("/api/classes/delete", {"name": "Period 4"})["classes"], [])

    def test_saving_an_invalid_roster_is_a_400(self):
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.post("/api/classes/save", {"name": "P4", "students": [{"id": "x", "name": "A"}]})
        self.assertEqual(caught.exception.code, 400)

    def test_settings_survive_a_reload(self):
        # This is the state that used to live in localStorage and vanish when
        # the ephemeral port changed the page's origin.
        self.post("/api/settings", {"test_name": "Unit 1", "selected_class": "Period 4"})
        self.assertEqual(self.get("/api/settings")["test_name"], "Unit 1")
        self.assertEqual(self.get("/api/settings")["selected_class"], "Period 4")

    def test_deleting_the_selected_class_clears_the_selection(self):
        self.post("/api/classes/save", {"name": "P4", "students": []})
        self.post("/api/settings", {"selected_class": "P4"})
        self.post("/api/classes/delete", {"name": "P4"})
        self.assertEqual(self.get("/api/settings")["selected_class"], "")

    def test_session_history_is_listed_and_exportable(self):
        session_id = self.controller_store().create_session("Unit 2", "P4", 30)
        self.controller_store().add_scan(
            session_id,
            {
                "number": 1,
                "role": "key",
                "received_at": "2026-09-16T18:00:00+00:00",
                "answered_count": 30,
                "responses": ["A"] * 30,
            },
        )
        listed = self.get("/api/sessions")["sessions"]
        self.assertEqual(listed[0]["name"], "Unit 2")
        self.assertEqual(listed[0]["scan_count"], 1)

        detail = self.get(f"/api/sessions/{session_id}")
        self.assertEqual(len(detail["scans"]), 1)

        with urllib.request.urlopen(
            self.base + f"/api/sessions/{session_id}/export.csv", timeout=5
        ) as response:
            disposition = response.headers["Content-Disposition"]
            body = response.read().decode()
        self.assertIn("Unit 2.csv", disposition)
        self.assertIn("Scan,Role,Class", body)
        self.assertIn("P4", body)

    def test_missing_session_is_404(self):
        for path in ("/api/sessions/999", "/api/sessions/999/export.csv"):
            with self.assertRaises(urllib.error.HTTPError) as caught:
                self.get(path)
            self.assertEqual(caught.exception.code, 404, path)

    def test_session_can_be_renamed_and_deleted(self):
        session_id = self.controller_store().create_session("Draft", "", 30)
        renamed = self.post("/api/sessions/rename", {"id": session_id, "name": "Final"})
        self.assertEqual(renamed["sessions"][0]["name"], "Final")
        self.assertEqual(self.post("/api/sessions/delete", {"id": session_id})["sessions"], [])

    def controller_store(self):
        return DataLinkRequestHandler.controller.store

    def test_a_correction_rewrites_the_sheet_and_rescores(self):
        store = self.controller_store()
        session_id = store.create_session("Unit 9", "P4", 5)
        store.add_scan(session_id, {"number": 1, "role": "key", "received_at": "2026-09-16T18:00:00+00:00",
                                    "answered_count": 5, "responses": ["A", "B", "C", "D", "E"]})
        store.add_scan(session_id, {"number": 2, "role": "student", "student_id": None,
                                    "received_at": "2026-09-16T18:00:00+00:00",
                                    "answered_count": 5, "responses": ["A", "B", "C", "D", "E"]})
        result = self.post("/api/sessions/correct", {
            "session_id": session_id,
            "corrections": [{"number": 2, "student_id": "900444"}],
        })
        self.assertEqual(result["applied"], 1)
        self.assertEqual(result["analysis"]["students"][0]["student_id"], "900444")
        self.assertEqual(result["analysis"]["review_items"], [])

    def test_a_correction_with_the_wrong_number_of_responses_is_rejected(self):
        store = self.controller_store()
        session_id = store.create_session("Unit 9", "P4", 5)
        store.add_scan(session_id, {"number": 1, "role": "key", "received_at": "x",
                                    "answered_count": 5, "responses": ["A"] * 5})
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.post("/api/sessions/correct", {
                "session_id": session_id,
                "corrections": [{"number": 1, "responses": ["A", "B"]}],
            })
        self.assertEqual(caught.exception.code, 400)

    def test_a_correction_rejects_a_non_letter_response(self):
        store = self.controller_store()
        session_id = store.create_session("Unit 9", "P4", 3)
        store.add_scan(session_id, {"number": 1, "role": "key", "received_at": "x",
                                    "answered_count": 3, "responses": ["A", "B", "C"]})
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.post("/api/sessions/correct", {
                "session_id": session_id,
                "corrections": [{"number": 1, "responses": ["A", "B", "Z"]}],
            })
        self.assertEqual(caught.exception.code, 400)

    def test_a_correction_rejects_a_non_numeric_student_id(self):
        store = self.controller_store()
        session_id = store.create_session("Unit 9", "P4", 3)
        store.add_scan(session_id, {"number": 1, "role": "student", "received_at": "x",
                                    "answered_count": 3, "responses": ["A", "B", "C"]})
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.post("/api/sessions/correct", {
                "session_id": session_id,
                "corrections": [{"number": 1, "student_id": "abc"}],
            })
        self.assertEqual(caught.exception.code, 400)

    def test_unknown_api_path_is_404(self):
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.post("/api/nope", {})
        self.assertEqual(caught.exception.code, 404)


if __name__ == "__main__":
    unittest.main()


class AppBundlePathTests(unittest.TestCase):
    """`brew upgrade` must not strand the /Applications symlink."""

    def test_cellar_path_is_rewritten_to_opt(self):
        import tempfile as tf

        from datalink_scanner.cli import stable_bundle_path

        with tf.TemporaryDirectory() as prefix:
            root = Path(prefix)
            cellar = root / "Cellar" / "datalink-scanner" / "1.0.0" / "DataLink Scanner.app"
            opt = root / "opt" / "datalink-scanner" / "DataLink Scanner.app"
            cellar.mkdir(parents=True)
            opt.mkdir(parents=True)
            self.assertEqual(stable_bundle_path(cellar), opt)

    def test_cellar_path_is_kept_when_opt_is_missing(self):
        import tempfile as tf

        from datalink_scanner.cli import stable_bundle_path

        with tf.TemporaryDirectory() as prefix:
            cellar = Path(prefix) / "Cellar" / "datalink-scanner" / "1.0.0" / "DataLink Scanner.app"
            cellar.mkdir(parents=True)
            self.assertEqual(stable_bundle_path(cellar), cellar)

    def test_non_homebrew_path_is_untouched(self):
        from datalink_scanner.cli import stable_bundle_path

        bundle = Path("/Users/someone/build/DataLink Scanner.app")
        self.assertEqual(stable_bundle_path(bundle), bundle)

"""Tests for the paper-scan path.

None of this runs the image pipeline: OpenCV is optional and a real batch
takes half a minute. What is worth pinning down is everything around it — the
environment the subprocess is handed, how its answers become scans, and that
the page cache is reported and emptied without touching a saved session.
"""

import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from datalink_scanner import paper
from datalink_scanner.store import Store


def report(students=2, question_count=3, key="ABC"):
    """The shape analyze_exam.py writes, cut down to what is read here."""
    return {
        "created_at": "2026-09-17T12:00:00+00:00",
        "exam": {
            "name": "Unit 2",
            "question_count": question_count,
            "key_page": 1,
            "source_type": "pdf_scan",
            "answer_key": [
                {"question": index + 1, "answer": letter}
                for index, letter in enumerate(key)
            ],
        },
        "students": [
            {
                "page": 2 + offset,
                "student_id": f"90001{offset}",
                "student_id_read": f"90001{offset}",
                "student_name": None,
                "answers": [
                    {"question": 1, "response": "A"},
                    {"question": 2, "response": "BLANK"},
                    {"question": 3, "response": "MULTIPLE"},
                ],
            }
            for offset in range(students)
        ],
    }


class EnvironmentTests(unittest.TestCase):
    def test_the_subprocess_can_find_the_vendored_modules(self):
        entries = paper.environment()["PYTHONPATH"].split(":")
        # analyze_exam.py imports its siblings AND analysis_core, which sits a
        # directory above it, so both have to be on the path.
        self.assertIn(str(paper.vendor_root()), entries)
        self.assertIn(str(paper.vendor_root() / "omr"), entries)
        self.assertIn(str(paper.support_dir()), entries)

    def test_homebrew_is_on_the_path_for_poppler(self):
        # A GUI app inherits PATH=/usr/bin:/bin, where pdftoppm is not.
        self.assertIn("/opt/homebrew/bin", paper.environment()["PATH"].split(":"))

    def test_the_pipeline_script_ships_with_the_package(self):
        self.assertTrue(paper.pipeline_script().is_file())
        self.assertTrue((paper.vendor_root() / "omr" / "reference_page.png").is_file())


class ProgressTests(unittest.TestCase):
    def test_rendering_is_the_first_half_and_reading_the_second(self):
        self.assertAlmostEqual(paper.progress_fraction("  Rendered 8/16 (PDF page 8)"), 0.25)
        self.assertAlmostEqual(paper.progress_fraction("  Read 8/16 (PDF page 8: ok)"), 0.75)
        self.assertAlmostEqual(paper.progress_fraction("  Read 16/16 (PDF page 9: ok)"), 1.0)

    def test_other_output_is_not_mistaken_for_progress(self):
        self.assertIsNone(paper.progress_fraction("Selected 15 of 15 pages for analysis."))
        self.assertIsNone(paper.progress_fraction(""))

    def test_a_zero_total_does_not_divide_by_zero(self):
        self.assertIsNone(paper.progress_fraction("  Read 0/0"))


class ResponseTests(unittest.TestCase):
    def test_the_pipelines_words_become_what_a_scan_stores(self):
        answers = [
            {"question": 1, "response": "C"},
            {"question": 2, "response": "BLANK"},
            {"question": 3, "response": "MULTIPLE"},
        ]
        # "" and "*" are exactly what a DataLink record carries, so the same
        # normalize_response() reads both sources identically.
        self.assertEqual(paper._responses(answers, 3), ["C", "", "*"])

    def test_a_question_the_pipeline_did_not_report_is_blank(self):
        self.assertEqual(paper._responses([{"question": 1, "response": "A"}], 3), ["A", "", ""])


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.store = Store(Path(self.temporary.name) / "library.sqlite3")
        self.addCleanup(self.store.close)

    def test_a_batch_becomes_an_ordinary_session(self):
        session_id = paper.session_from_report(self.store, report(), name="Unit 2")
        session = self.store.session(session_id)
        scans = self.store.session_scans(session_id)
        self.assertEqual(session["name"], "Unit 2")
        self.assertEqual(session["question_count"], 3)
        self.assertEqual(len([s for s in scans if s["role"] == "key"]), 1)
        self.assertEqual(len([s for s in scans if s["role"] == "student"]), 2)

    def test_the_session_records_that_it_came_from_paper(self):
        # Which is what makes the exported JSON say pdf_scan rather than
        # claiming the sheets came off the device.
        session_id = paper.session_from_report(self.store, report())
        self.assertEqual(self.store.session(session_id)["source"], "paper")

    def test_a_datalink_session_is_still_marked_as_one(self):
        session_id = self.store.create_session("Live", "", 10)
        self.assertEqual(self.store.session(session_id)["source"], "datalink")

    def test_the_key_page_keeps_its_page_number(self):
        session_id = paper.session_from_report(self.store, report())
        key = [s for s in self.store.session_scans(session_id) if s["role"] == "key"][0]
        self.assertEqual(key["number"], 1)
        self.assertEqual(key["responses"], ["A", "B", "C"])

    def test_students_are_named_from_the_roster_when_one_is_chosen(self):
        self.store.save_class("Period 4", [{"id": "900010", "name": "Ada L."}])
        session_id = paper.session_from_report(
            self.store, report(), class_name="Period 4"
        )
        named = {
            s["student_id"]: s["student_name"]
            for s in self.store.session_scans(session_id)
            if s["role"] == "student"
        }
        self.assertEqual(named["900010"], "Ada L.")
        self.assertIsNone(named["900011"])

    def test_a_batch_with_no_students_is_refused(self):
        empty = report()
        empty["students"] = []
        with self.assertRaises(paper.PaperError):
            paper.session_from_report(self.store, empty)

    def test_a_key_that_does_not_match_the_question_count_is_refused(self):
        wrong = report(question_count=5)
        with self.assertRaises(paper.PaperError) as caught:
            paper.session_from_report(self.store, wrong)
        self.assertIn("answer key", str(caught.exception))


class StorageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.captures = Path(self.temporary.name)
        cache = self.captures / paper.CACHE_DIRNAME / "batch-1"
        cache.mkdir(parents=True)
        (cache / "page-000001.png").write_bytes(b"x" * 2048)
        (cache / "page-000002.png").write_bytes(b"x" * 2048)

    def test_the_cache_is_reported_per_batch(self):
        found = paper.cache_report(self.captures)
        self.assertEqual(found["batches"], 1)
        self.assertEqual(found["cache_bytes"], 4096)
        self.assertFalse(found["over_limit"])

    def test_going_over_the_limit_is_flagged(self):
        with mock.patch.object(paper, "CACHE_WARN_BYTES", 1024):
            self.assertTrue(paper.cache_report(self.captures)["over_limit"])

    def test_purging_removes_the_pages_and_reports_what_it_freed(self):
        result = paper.purge_cache(self.captures)
        self.assertEqual(result["freed_bytes"], 4096)
        self.assertEqual(result["cache_bytes"], 0)
        self.assertEqual(result["batches"], 0)

    def test_purging_an_empty_cache_is_not_an_error(self):
        paper.purge_cache(self.captures)
        self.assertEqual(paper.purge_cache(self.captures)["freed_bytes"], 0)

    def test_purging_leaves_the_saved_sessions_alone(self):
        database = self.captures / "library.sqlite3"
        store = Store(database)
        store.create_session("Unit 2", "", 10)
        store.close()
        paper.purge_cache(self.captures)
        self.assertTrue(database.is_file())
        store = Store(database)
        self.assertEqual(len(store.list_sessions()), 1)
        store.close()


class SupportTests(unittest.TestCase):
    def completed(self, code=0, out=""):
        return subprocess.CompletedProcess(args=[], returncode=code, stdout=out, stderr="")

    def test_status_is_ready_when_everything_imports(self):
        runner = mock.Mock(return_value=self.completed(0, "5.0.0\n"))
        with mock.patch.object(paper, "missing_tools", return_value=[]):
            found = paper.status(runner)
        self.assertTrue(found["ready"])
        self.assertEqual(found["opencv_version"], "5.0.0")

    def test_missing_packages_are_reported_separately_from_poppler(self):
        runner = mock.Mock(return_value=self.completed(1))
        with mock.patch.object(paper, "missing_tools", return_value=["pdftoppm"]):
            found = paper.status(runner)
        self.assertFalse(found["ready"])
        self.assertEqual(sorted(found["missing"]), ["packages", "poppler"])

    def test_a_build_without_pip_says_so_rather_than_failing_later(self):
        with mock.patch.object(paper, "pip_available", return_value=False):
            with self.assertRaises(paper.PaperError) as caught:
                paper.install_packages()
        self.assertIn("Homebrew", str(caught.exception))

    def test_reading_a_pdf_without_poppler_explains_the_fix(self):
        with mock.patch.object(paper, "tool_path", return_value=None):
            with self.assertRaises(paper.PaperError) as caught:
                paper.page_count("/tmp/whatever.pdf")
        self.assertIn("brew install poppler", str(caught.exception))


class JobTests(unittest.TestCase):
    def test_a_job_reports_progress_and_its_result(self):
        job = paper.Job()
        done = __import__("threading").Event()

        def work(report_progress):
            report_progress(progress=0.5, message="halfway")
            return {"session_id": 7, "message": "Read 3 sheets"}

        job.start("reading", "starting", work)
        for _ in range(200):
            if job.state == "done":
                break
            __import__("time").sleep(0.01)
        snapshot = job.snapshot()
        self.assertEqual(snapshot["state"], "done")
        self.assertEqual(snapshot["session_id"], 7)
        self.assertEqual(snapshot["progress"], 1.0)

    def test_a_failure_is_kept_for_the_page_to_show(self):
        job = paper.Job()

        def work(report_progress):
            raise paper.PaperError("key page 4 was not readable")

        job.start("reading", "starting", work)
        for _ in range(200):
            if job.state == "failed":
                break
            __import__("time").sleep(0.01)
        self.assertEqual(job.snapshot()["state"], "failed")
        self.assertIn("key page 4", job.snapshot()["message"])

    def test_two_batches_at_once_are_refused(self):
        job = paper.Job()
        release = __import__("threading").Event()
        job.start("reading", "starting", lambda report_progress: release.wait(5) and None)
        try:
            with self.assertRaises(paper.PaperError):
                job.start("reading", "starting", lambda report_progress: None)
        finally:
            release.set()

    def test_a_finished_job_can_be_cleared_but_a_running_one_cannot(self):
        job = paper.Job()
        job.start("reading", "starting", lambda report_progress: {"message": "done"})
        for _ in range(200):
            if not job.busy:
                break
            __import__("time").sleep(0.01)
        job.reset()
        self.assertEqual(job.state, "idle")


class FrozenBuildTests(unittest.TestCase):
    """The disk-image build has no Python to spawn and no Homebrew to borrow."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        # Contents/MacOS/<app> is where a frozen sys.executable lives.
        self.macos = Path(self.temporary.name) / "Contents" / "MacOS"
        self.macos.mkdir(parents=True)
        self.helpers = Path(self.temporary.name) / "Contents" / "Helpers"
        self.helpers.mkdir(parents=True)
        for name in ("pdftoppm", "pdfinfo"):
            tool = self.helpers / name
            tool.write_text("#!/bin/sh\nexit 0\n")
            tool.chmod(0o755)
        self.executable = self.macos / "DataLink Scanner"
        self.executable.write_text("")

    def frozen(self):
        return mock.patch.multiple(
            paper.sys, frozen=True, executable=str(self.executable), create=True
        )

    def test_the_pipeline_re_enters_the_app_instead_of_python(self):
        with self.frozen():
            command = paper.pipeline_command()
        # sys.executable is the app itself, so passing it a script would open
        # a second window rather than read any sheets.
        self.assertEqual(command, [str(self.executable), paper.RUN_FLAG])

    def test_an_ordinary_install_still_runs_the_script(self):
        command = paper.pipeline_command()
        self.assertEqual(command[1], str(paper.pipeline_script()))

    def test_the_bundled_poppler_is_preferred_over_homebrew(self):
        with self.frozen():
            found = paper.tool_path("pdftoppm")
        self.assertEqual(Path(found), (self.helpers / "pdftoppm").resolve())

    def test_the_bundled_tools_are_put_on_the_path(self):
        with self.frozen():
            entries = paper.environment()["PATH"].split(":")
        # The vendored reader calls pdftoppm by bare name.
        self.assertEqual(Path(entries[0]), self.helpers.resolve())

    def test_a_frozen_build_never_claims_it_can_install_packages(self):
        # Asking would run `<the app> -m pip`, which opens a second window.
        with self.frozen():
            with mock.patch.object(paper.subprocess, "run") as run:
                self.assertFalse(paper.pip_available())
        run.assert_not_called()

    def test_the_readiness_probe_re_enters_the_app_too(self):
        with self.frozen():
            with mock.patch.object(paper.subprocess, "run") as run:
                run.return_value = subprocess.CompletedProcess(
                    args=[], returncode=0, stdout="5.0.0", stderr=""
                )
                ready, version = paper.packages_ready(run)
        self.assertTrue(ready)
        self.assertEqual(version, "5.0.0")
        self.assertEqual(run.call_args.args[0][1:], [paper.RUN_FLAG, paper.PROBE_FLAG])

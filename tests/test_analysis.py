"""Item analysis: the scoring is vendored, so these tests guard the seams.

What can break here is not the maths — that is a verbatim copy of the omr_final
modules — but the adapter feeding it, and the copies drifting from the
originals.
"""

import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from datalink_scanner.analysis import (
    AnalysisError,
    analysis_filename,
    build_session_analysis,
    normalize_response,
)

OMR_FINAL = Path("/Users/davidhohnholt/school_projects/Datalink/omr_final")
VENDOR = Path(__file__).resolve().parents[1] / "src" / "datalink_scanner" / "vendor"


def session(question_count=5, name="Unit 1", log_path=None):
    return {
        "id": 1,
        "name": name,
        "class_name": "Period 4",
        "question_count": question_count,
        "started_at": "2026-09-16T18:00:00+00:00",
        "ended_at": None,
        "log_path": log_path,
    }


def scan(number, role, responses, student_id=None, student_name=None):
    return {
        "number": number,
        "role": role,
        "student_id": student_id,
        "student_name": student_name,
        "received_at": "2026-09-16T18:00:00+00:00",
        "answered_count": sum(1 for value in responses if value),
        "responses": responses,
        "demo": False,
    }


class VendorTests(unittest.TestCase):
    @unittest.skipUnless(OMR_FINAL.is_dir(), "omr_final is not on this machine")
    def test_the_vendored_copies_match_the_originals(self):
        """The whole point is one scoring implementation. If omr_final changes,
        re-copy rather than editing the copy here."""
        for name in ("analysis_core.py", "result_schema.py"):
            self.assertEqual(
                (VENDOR / name).read_bytes(),
                (OMR_FINAL / name).read_bytes(),
                f"{name} has drifted from omr_final; re-copy it",
            )


class NormalizeTests(unittest.TestCase):
    def test_matches_the_csv_importers_rules(self):
        self.assertEqual(normalize_response(""), "BLANK")
        self.assertEqual(normalize_response(None), "BLANK")
        self.assertEqual(normalize_response("  "), "BLANK")
        self.assertEqual(normalize_response("c"), "C")
        self.assertEqual(normalize_response("*"), "MULTIPLE")
        self.assertEqual(normalize_response("AC"), "MULTIPLE")

    def test_rejects_anything_else(self):
        with self.assertRaises(AnalysisError):
            normalize_response("Z")


class BuildTests(unittest.TestCase):
    def test_scores_a_small_session(self):
        scans = [
            scan(1, "key", ["A", "B", "C", "D", "E"]),
            scan(2, "student", ["A", "B", "C", "D", "E"], "900011", "All right"),
            scan(3, "student", ["A", "B", "C", "E", ""], "900012", "Two wrong"),
        ]
        report = build_session_analysis(session(), scans)
        self.assertEqual(report["schema_version"], "1.0")
        self.assertEqual(len(report["students"]), 2)
        self.assertEqual(len(report["items"]), 5)
        self.assertEqual(report["students"][0]["score"]["correct"], 5)
        self.assertEqual(report["students"][1]["score"]["correct"], 3)
        self.assertEqual(report["students"][1]["score"]["blank"], 1)
        self.assertEqual(report["summary"]["student_count"], 2)

    def test_trailing_blanks_count_as_blank_not_missing(self):
        # The form length decides how many slots exist; a short row is padded.
        scans = [
            scan(1, "key", ["A"] * 5),
            scan(2, "student", ["A", "A"], "900011"),
        ]
        report = build_session_analysis(session(), scans)
        self.assertEqual(report["students"][0]["score"]["blank"], 3)
        self.assertEqual(len(report["students"][0]["answers"]), 5)

    def test_double_marks_become_review_items(self):
        scans = [
            scan(1, "key", ["A"] * 5),
            scan(2, "student", ["A", "AC", "A", "A", "A"], "900011"),
        ]
        report = build_session_analysis(session(), scans)
        self.assertEqual(report["students"][0]["score"]["multiple"], 1)
        self.assertIn(
            {"page": 2, "field": "answer", "question": 2, "value": "MULTIPLE"},
            report["review_items"],
        )

    def test_a_missing_student_id_becomes_a_review_item(self):
        scans = [scan(1, "key", ["A"] * 5), scan(2, "student", ["A"] * 5)]
        report = build_session_analysis(session(), scans)
        self.assertIn(
            {"page": 2, "field": "student_id", "value": None}, report["review_items"]
        )

    def test_refuses_a_session_without_exactly_one_key(self):
        with self.assertRaises(AnalysisError) as caught:
            build_session_analysis(session(), [scan(1, "student", ["A"] * 5)])
        self.assertIn("answer key", str(caught.exception))

        with self.assertRaises(AnalysisError):
            build_session_analysis(
                session(), [scan(1, "key", ["A"] * 5), scan(2, "key", ["A"] * 5)]
            )

    def test_refuses_a_session_with_no_students(self):
        with self.assertRaises(AnalysisError) as caught:
            build_session_analysis(session(), [scan(1, "key", ["A"] * 5)])
        self.assertIn("student sheets", str(caught.exception))

    def test_refuses_an_unresolved_answer_key(self):
        # A key with a double mark cannot score anything.
        scans = [
            scan(1, "key", ["A", "AB", "C", "D", "E"]),
            scan(2, "student", ["A"] * 5, "900011"),
        ]
        with self.assertRaises(AnalysisError) as caught:
            build_session_analysis(session(), scans)
        self.assertIn("question(s) 2", str(caught.exception))

    def test_filename_follows_the_session_name(self):
        self.assertEqual(analysis_filename(session(name="Unit 3 Exam")), "Unit 3 Exam.json")
        self.assertEqual(analysis_filename(session(name="")), "datalink-session.json")

    def test_source_type_stays_what_the_website_already_accepts(self):
        scans = [scan(1, "key", ["A"] * 5), scan(2, "student", ["A"] * 5, "900011")]
        report = build_session_analysis(session(), scans)
        self.assertEqual(report["exam"]["source_type"], "datalink_csv")


class ParityTests(unittest.TestCase):
    """The app's JSON and omr_final's JSON must agree for the same scans."""

    @unittest.skipUnless(
        (OMR_FINAL / "analyze_datalink_csv.py").is_file(),
        "omr_final is not on this machine",
    )
    def test_direct_output_matches_the_csv_importer(self):
        from datalink_scanner.server import records_to_csv

        key = ["A", "B", "C", "D", "E"] * 4
        rows = [scan(1, "key", key)]
        for index in range(6):
            responses = list(key)
            responses[index] = "E" if key[index] != "E" else "A"
            if index == 3:
                responses[10] = ""
            rows.append(
                scan(index + 2, "student", responses, f"90001{index}", f"Student {index}")
            )
        current = session(question_count=20, name="Parity")

        mine = build_session_analysis(current, rows)

        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            (work / "export.csv").write_bytes(
                records_to_csv(rows, current["class_name"], current["question_count"])
            )
            subprocess.run(
                [
                    sys.executable,
                    "analyze_datalink_csv.py",
                    str(work / "export.csv"),
                    "--exam-name",
                    "Parity",
                    "--out",
                    str(work / "out"),
                ],
                cwd=OMR_FINAL,
                check=True,
                capture_output=True,
            )
            theirs = json.loads((work / "out" / "analysis_result.json").read_text())

        for document in (mine, theirs):
            document.pop("run_id")
            document.pop("created_at")
            document["exam"].pop("source_file")
        self.assertEqual(mine, theirs)


if __name__ == "__main__":
    unittest.main()


class AnalysisPageTests(unittest.TestCase):
    """The page mirrors omr_final's results view, so an item that reads as
    Priority there must read as Priority here."""

    def setUp(self):
        root = Path(__file__).resolve().parents[1] / "src" / "datalink_scanner"
        self.html = (root / "webui" / "index.html").read_text()
        self.js = (root / "webui" / "app.js").read_text()

    def test_the_view_and_its_tab_exist(self):
        self.assertIn('data-view="analysis"', self.html)
        self.assertIn('id="view-analysis"', self.html)

    def test_it_reads_the_inline_endpoint_not_the_download(self):
        # The download variant sets Content-Disposition, which a fetch for the
        # page should not be using.
        self.assertIn("}/analysis`", self.js)

    @unittest.skipUnless((OMR_FINAL / "app.py").is_file(), "omr_final is not on this machine")
    def test_status_cut_points_match_omr_final(self):
        import re

        source = (OMR_FINAL / "app.py").read_text()
        theirs = re.search(
            r'"Priority" if value < (\d+) else "Developing" if value < (\d+) else "Secure"',
            source,
        )
        self.assertIsNotNone(theirs, "omr_final's status thresholds moved")
        priority_below, secure_at = (int(value) for value in theirs.groups())

        mine_priority = int(re.search(r"PRIORITY_BELOW = (\d+)", self.js).group(1))
        mine_secure = int(re.search(r"SECURE_AT = (\d+)", self.js).group(1))
        self.assertEqual((mine_priority, mine_secure), (priority_below, secure_at))

    def test_every_status_bucket_is_offered_as_a_filter(self):
        filters = set(re.findall(r'data-filter="(\w+)"', self.html))
        self.assertEqual(filters, {"all", "priority", "developing", "secure", "flagged"})

    def test_diagnostics_start_collapsed(self):
        wrap = self.html[self.html.index('id="diagnosticsWrap"') :]
        self.assertIn("hidden", wrap[: wrap.index(">")])

    def test_pane_switching_does_not_hide_the_sub_tabs(self):
        # The tab buttons carry data-pane as well, so the selector that hides
        # panes has to be scoped to direct children of the body.
        self.assertIn('"#analysisBody > [data-pane]"', self.js)

    def test_review_and_answer_key_panes_exist(self):
        for pane in ("review", "key"):
            self.assertIn(f'data-pane="{pane}"', self.html)
        self.assertIn("applyReviewButton", self.html)
        self.assertIn("saveKeyButton", self.html)


class RunIdStabilityTests(unittest.TestCase):
    """A retry must land on the same audit record; a corrected re-score must
    become a new one."""

    def setUp(self):
        import tempfile
        from datalink_scanner.store import Store

        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.store = Store(Path(self.directory.name) / "library.sqlite3")
        self.addCleanup(self.store.close)
        self.session_id = self.store.create_session("Unit 4", "P4", 5)
        self.store.add_scan(self.session_id, {
            "number": 1, "role": "key", "received_at": "2026-09-16T18:00:00+00:00",
            "answered_count": 5, "responses": ["A", "B", "C", "D", "E"]})
        self.store.add_scan(self.session_id, {
            "number": 2, "role": "student", "student_id": "900011",
            "received_at": "2026-09-16T18:00:00+00:00",
            "answered_count": 5, "responses": ["A", "B", "C", "D", "E"]})

    def score(self):
        from datalink_scanner.server import scored_session

        return scored_session(self.store, self.session_id)[1]

    def test_rescoring_unchanged_scans_keeps_the_run_id(self):
        self.assertEqual(self.score()["run_id"], self.score()["run_id"])

    def test_correcting_a_student_id_produces_a_new_run_id(self):
        first = self.score()["run_id"]
        self.store.update_scan(self.session_id, 2, student_id="900222")
        self.assertNotEqual(self.score()["run_id"], first)

    def test_changing_the_answer_key_produces_a_new_run_id(self):
        first = self.score()["run_id"]
        self.store.update_scan(self.session_id, 1, responses=["B", "B", "C", "D", "E"])
        self.assertNotEqual(self.score()["run_id"], first)

    def test_changing_a_student_response_produces_a_new_run_id(self):
        first = self.score()["run_id"]
        self.store.update_scan(self.session_id, 2, responses=["E", "B", "C", "D", "E"])
        self.assertNotEqual(self.score()["run_id"], first)

    def test_reverting_a_correction_returns_to_a_stable_id_not_the_old_one(self):
        # Going back to the original marks is still a fresh scoring run.
        first = self.score()["run_id"]
        self.store.update_scan(self.session_id, 2, student_id="900222")
        second = self.score()["run_id"]
        self.store.update_scan(self.session_id, 2, student_id="900011")
        third = self.score()["run_id"]
        self.assertNotEqual(second, first)
        self.assertEqual(third, self.score()["run_id"])

    def test_the_fingerprint_covers_what_the_score_depends_on(self):
        from datalink_scanner.analysis import scan_fingerprint

        session = self.store.session(self.session_id)
        scans = self.store.session_scans(self.session_id)
        before = scan_fingerprint(session, scans)
        self.assertEqual(before, scan_fingerprint(session, list(reversed(scans))))
        self.store.update_scan(self.session_id, 2, student_name="Renamed")
        after = scan_fingerprint(session, self.store.session_scans(self.session_id))
        self.assertNotEqual(before, after)

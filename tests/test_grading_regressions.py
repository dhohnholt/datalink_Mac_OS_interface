"""Focused regressions for capture durability and grading corrections."""
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock

from datalink_scanner.analysis import build_session_analysis
from datalink_scanner.interface import DataLinkFormRecord, DataLinkStreamParser
from datalink_scanner.paper import session_from_report
from datalink_scanner.server import DataLinkRequestHandler, ScannerController
from datalink_scanner.store import Store
from support import build_line
from test_paper import report


class GradingRegressions(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.store = Store(self.root / 'test.sqlite3')
        self.addCleanup(lambda: self.store.close())
        self.controller = ScannerController(self.root, self.store)

    def post(self, body):
        handler = object.__new__(DataLinkRequestHandler)
        handler.controller = self.controller
        handler.path = '/api/sessions/correct'
        raw = json.dumps(body).encode()
        handler.headers = {'Content-Length': str(len(raw))}
        handler.rfile = io.BytesIO(raw)
        result = []
        handler._send_json = lambda payload, status=200: result.append((status, payload))
        handler.do_POST()
        return result[0]

    def capture(self):
        session = self.controller.start_session(3)
        scanner = Mock(parser=DataLinkStreamParser(3))
        self.controller._scanner = scanner
        def read():
            self.controller._stop.set()
            return ([DataLinkFormRecord.from_line(build_line(values), 3)
                     for values in (['A', 'B', 'C'], ['A', 'BC', 'C'])], [])
        scanner.read_available.side_effect = read
        self.controller._read_loop()
        self.assertIsNone(self.controller.snapshot()['error'])
        return session

    def test_question_count_changes_in_both_directions(self):
        scanner = Mock(parser=DataLinkStreamParser(30))
        self.controller._scanner = scanner
        for count in (50, 20):
            session = self.controller.start_session(count)
            records, _ = scanner.parser.feed(build_line(['A'] * 50) + b'\r\n')
            self.assertEqual(len(records[0].responses), count)
            self.assertEqual(self.store.session(session)['question_count'], count)
            self.controller.end_session()

    def test_pending_capture_survives_restart_and_session_end(self):
        session = self.capture()
        log = Path(self.store.session(session)['log_path'])
        self.assertEqual(len(log.read_text().splitlines()), 2)
        # Open a second connection before ending: the pending sheet is durable
        # even if the process stops without performing normal shutdown.
        reopened = Store(self.root / 'test.sqlite3')
        try:
            scans = reopened.session_scans(session)
            self.assertEqual(len(scans), 2)
            self.assertTrue(scans[1]['pending_review'])
            analysis = build_session_analysis(reopened.session(session), scans)
            self.assertIn('pending_review', [r.get('reason') for r in analysis['review_items']])
        finally:
            reopened.close()
        summary = self.controller.end_session()
        self.assertEqual(summary['discarded'], 0)
        self.assertEqual(summary['sheets'], 1)
        self.assertEqual(len(self.store.session_scans(session)), 2)

    def test_resolving_live_review_updates_instead_of_duplicating(self):
        session = self.capture()
        self.controller.resolve_review(2, {'2': 'B'}, '900001', 'Synthetic')
        scans = self.store.session_scans(session)
        self.assertEqual(len(scans), 2)
        self.assertFalse(scans[1]['pending_review'])
        self.assertEqual(scans[1]['responses'], ['A', 'B', 'C'])

    def test_uncertain_paper_id_remains_reviewable(self):
        source = report(students=1)
        source['students'][0].update(student_id=None, student_id_read='90??01')
        session = session_from_report(self.store, source)
        analysis = build_session_analysis(self.store.session(session), self.store.session_scans(session))
        self.assertIsNone(analysis['students'][0]['student_id'])
        self.assertEqual(analysis['students'][0]['student_id_read'], '90??01')
        self.assertTrue(any(r['field'] == 'student_id' for r in analysis['review_items']))

    def test_invalid_batch_does_not_save_or_dismiss_anything(self):
        session = session_from_report(self.store, report(students=1))
        before = self.store.session_scans(session)
        status, _ = self.post({'session_id': session, 'dismiss': ['2:answer:3:multiple'],
            'corrections': [{'number': 2, 'student_id': '900999'},
                            {'number': 1, 'responses': ['Z', 'B', 'C']}]})
        self.assertEqual(status, 400)
        self.assertEqual(self.store.session_scans(session), before)
        self.assertEqual(self.store.dismissed_reviews(session), set())

    def test_missing_sheet_rolls_back_prior_update(self):
        session = session_from_report(self.store, report(students=1))
        before = self.store.session_scans(session)
        status, _ = self.post({'session_id': session, 'dismiss': ['2:answer:3:multiple'],
            'corrections': [{'number': 2, 'student_id': '900999'},
                            {'number': 999, 'student_id': '900888'}]})
        self.assertEqual(status, 400)
        self.assertEqual(self.store.session_scans(session), before)
        self.assertEqual(self.store.dismissed_reviews(session), set())

    def test_correction_preserves_other_multiple_marks(self):
        session = session_from_report(self.store, report(students=1))
        for multiple in ('MULTIPLE', '*', 'AC'):
            status, payload = self.post({'session_id': session, 'corrections': [
                {'number': 2, 'responses': ['B', 'BLANK', multiple]}]})
            self.assertEqual(status, 200, payload)
            self.assertEqual(payload['analysis']['students'][0]['answers'][2]['response'], 'MULTIPLE')
            self.assertEqual(self.store.session_scans(session)[1]['responses'][:2], ['B', ''])

    def test_dismiss_only_is_saved_atomically(self):
        session = session_from_report(self.store, report(students=1))
        status, payload = self.post({'session_id': session, 'dismiss': ['2:answer:3:multiple']})
        self.assertEqual(status, 200, payload)
        self.assertEqual(payload['dismissed'], 1)
        self.assertEqual(payload['analysis']['review_items'], [])

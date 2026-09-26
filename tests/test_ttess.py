"""Tests for the T-TESS upload client.

Nothing here touches the real service or the real Keychain. What matters is
the handling around the call: which failures may be retried, which must not,
that a retry keeps its run_id, and that the token never leaks.
"""

import json
import unittest
from unittest import mock

from datalink_scanner import ttess


def analysis(run_id="run-1", size=1):
    return {
        "schema_version": "1.0",
        "run_id": run_id,
        "exam": {"name": "Unit 4", "source_type": "datalink_csv", "padding": "x" * size},
        "students": [],
        "items": [],
    }


class TokenTests(unittest.TestCase):
    def test_rejects_a_token_without_the_expected_prefix(self):
        with mock.patch.object(ttess.keychain, "set_password") as stored:
            with self.assertRaises(ttess.UploadError) as caught:
                ttess.save_token("not-a-real-token")
        self.assertEqual(caught.exception.code, "malformed_token")
        stored.assert_not_called()

    def test_rejects_an_empty_token(self):
        with self.assertRaises(ttess.UploadError) as caught:
            ttess.save_token("   ")
        self.assertEqual(caught.exception.code, "empty_token")

    def test_stores_a_valid_token_in_the_keychain_only(self):
        with mock.patch.object(ttess.keychain, "set_password") as stored:
            ttess.save_token("  dlk_live_abc123  ")
        stored.assert_called_once_with(
            ttess.KEYCHAIN_SERVICE, ttess.KEYCHAIN_ACCOUNT, "dlk_live_abc123"
        )

    def test_the_keychain_coordinates_match_the_specification(self):
        self.assertEqual(ttess.KEYCHAIN_SERVICE, "org.tmechs.datalink")
        self.assertEqual(ttess.KEYCHAIN_ACCOUNT, "scantron-upload-token")


class PreparationTests(unittest.TestCase):
    def test_stamps_the_destination_and_marks_the_source(self):
        prepared, _ = ttess.prepare_analysis(analysis(), "ECON-U2-5-5WT")
        self.assertEqual(prepared["exam"]["test_code"], "ECON-U2-5-5WT")
        self.assertEqual(prepared["exam"]["source_type"], "datalink_direct")

    def test_keeps_schema_version_and_run_id(self):
        prepared, _ = ttess.prepare_analysis(analysis(run_id="keep-me"), "T")
        self.assertEqual(prepared["schema_version"], "1.0")
        self.assertEqual(prepared["run_id"], "keep-me")

    def test_does_not_mutate_the_caller_s_report(self):
        original = analysis()
        ttess.prepare_analysis(original, "T")
        self.assertEqual(original["exam"]["source_type"], "datalink_csv")
        self.assertNotIn("test_code", original["exam"])

    def test_refuses_an_oversized_analysis_before_sending(self):
        with self.assertRaises(ttess.UploadError) as caught:
            ttess.prepare_analysis(analysis(size=ttess.MAX_ANALYSIS_BYTES + 1), "T")
        self.assertEqual(caught.exception.code, "payload_too_large")

    def test_the_limit_matches_the_specification(self):
        self.assertEqual(ttess.MAX_ANALYSIS_BYTES, 5_242_880)


class UploadTests(unittest.TestCase):
    def send(self, responses, **kwargs):
        """Run an upload against a scripted sequence of server responses."""
        calls = []
        slept = []

        def fake_request(method, body, bearer):
            calls.append({"method": method, "bearer": bearer, "body": body})
            outcome = responses[min(len(calls) - 1, len(responses) - 1)]
            if isinstance(outcome, Exception):
                raise outcome
            return outcome

        with mock.patch.object(ttess, "_request", side_effect=fake_request):
            try:
                result = ttess.upload(
                    "exam-1", analysis(), "CODE", bearer="dlk_live_x",
                    sleep=slept.append, **kwargs
                )
                return result, calls, slept, None
            except ttess.UploadError as exc:
                return None, calls, slept, exc

    def test_a_created_response_returns_the_review_url(self):
        result, calls, _, error = self.send([
            (201, {"run_id": "db-run", "status": "imported",
                   "review_url": "https://ttess.tmechsmonitor.org/x?run=1"}),
        ])
        self.assertIsNone(error)
        self.assertEqual(result["run_id"], "db-run")
        self.assertEqual(result["status"], "imported")
        self.assertIn("run=1", result["review_url"])
        self.assertEqual(len(calls), 1)

    def test_the_token_travels_as_a_bearer_and_not_in_the_body(self):
        _, calls, _, _ = self.send([(201, {"run_id": "r"})])
        self.assertEqual(calls[0]["bearer"], "dlk_live_x")
        self.assertNotIn(b"dlk_live_x", calls[0]["body"])

    def test_the_body_is_raw_json_with_exam_id_and_analysis(self):
        _, calls, _, _ = self.send([(201, {"run_id": "r"})])
        body = json.loads(calls[0]["body"])
        self.assertEqual(sorted(body), ["analysis", "exam_id"])
        self.assertEqual(body["exam_id"], "exam-1")
        self.assertEqual(body["analysis"]["exam"]["source_type"], "datalink_direct")

    def test_a_draft_replacement_is_explicit_in_the_body_and_result(self):
        result, calls, _, error = self.send([
            (200, {"run_id": "new-db-run", "status": "updated",
                   "replaced_run_id": "old-db-run"}),
        ], replace_run_id="old-db-run")
        self.assertIsNone(error)
        body = json.loads(calls[0]["body"])
        self.assertEqual(body["replace_run_id"], "old-db-run")
        self.assertEqual(result["status"], "updated")
        self.assertEqual(result["replaced_run_id"], "old-db-run")

    def test_an_unavailable_service_is_retried_twice_then_reported(self):
        _, calls, slept, error = self.send([(503, {"error": {"code": "service_unavailable"}})])
        self.assertEqual(error.code, "service_unavailable")
        self.assertEqual(len(calls), 3)          # first attempt plus two retries
        self.assertEqual(slept, [1, 2])          # exponential backoff

    def test_a_retry_sends_the_identical_body_so_the_run_id_is_unchanged(self):
        _, calls, _, _ = self.send([
            (503, {"error": {"code": "service_unavailable"}}),
            (201, {"run_id": "db-run"}),
        ])
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[0]["body"], calls[1]["body"])
        self.assertEqual(json.loads(calls[0]["body"])["analysis"]["run_id"], "run-1")

    def test_a_duplicate_run_is_never_retried(self):
        _, calls, slept, error = self.send([
            (409, {"error": {"code": "duplicate_run", "message": "Already uploaded"}}),
        ])
        self.assertEqual(error.code, "duplicate_run")
        self.assertEqual(error.args[0], "Already uploaded")
        self.assertEqual(len(calls), 1)
        self.assertEqual(slept, [])

    def test_finalized_results_are_not_reported_as_duplicate_runs(self):
        _, calls, slept, error = self.send([
            (409, {"error": {"code": "run_not_replaceable",
                              "message": "Finalized results cannot be replaced"}}),
        ])
        self.assertEqual(error.code, "run_not_replaceable")
        self.assertEqual(error.args[0], "Finalized results cannot be replaced")
        self.assertEqual(len(calls), 1)
        self.assertEqual(slept, [])

    def test_a_payload_too_large_response_is_never_retried(self):
        _, calls, _, error = self.send([(413, {"error": {"code": "payload_too_large"}})])
        self.assertEqual(error.code, "payload_too_large")
        self.assertEqual(len(calls), 1)

    def test_a_validation_failure_shows_the_server_message_and_stops(self):
        _, calls, _, error = self.send([
            (422, {"error": {"code": "validation_failed",
                             "message": "answer_key must have 50 entries"}}),
        ])
        self.assertEqual(error.code, "validation_failed")
        self.assertEqual(error.args[0], "answer_key must have 50 entries")
        self.assertEqual(len(calls), 1)

    def test_a_forbidden_exam_is_not_retried(self):
        _, calls, _, error = self.send([(403, {"error": {"code": "exam_forbidden"}})])
        self.assertEqual(error.code, "exam_forbidden")
        self.assertEqual(len(calls), 1)

    def test_an_invalid_token_is_removed_from_the_keychain(self):
        with mock.patch.object(ttess.keychain, "delete_password") as forgotten:
            _, calls, _, error = self.send([(401, {"error": {"code": "invalid_token"}})])
        self.assertEqual(error.code, "invalid_token")
        self.assertEqual(len(calls), 1)
        forgotten.assert_called_once_with(
            ttess.KEYCHAIN_SERVICE, ttess.KEYCHAIN_ACCOUNT
        )

    def test_uploading_without_a_destination_is_refused_locally(self):
        with self.assertRaises(ttess.UploadError) as caught:
            ttess.upload("", analysis(), "CODE", bearer="dlk_live_x")
        self.assertEqual(caught.exception.code, "no_destination")

    def test_uploading_without_a_token_is_refused_locally(self):
        with mock.patch.object(ttess, "token", return_value=None):
            with self.assertRaises(ttess.UploadError) as caught:
                ttess.upload("exam-1", analysis(), "CODE")
        self.assertEqual(caught.exception.code, "not_connected")


class TransportTests(unittest.TestCase):
    def test_an_http_url_is_refused(self):
        with mock.patch.object(ttess, "API_URL", "http://example.com/api"):
            with self.assertRaises(ttess.UploadError) as caught:
                ttess._request("GET", None, "dlk_live_x")
        self.assertEqual(caught.exception.code, "insecure_url")

    def test_the_configured_endpoints_match_the_specification(self):
        self.assertEqual(
            ttess.API_URL,
            "https://zgrxawyginizrshjmkum.supabase.co/functions/v1/datalink-api",
        )
        self.assertTrue(
            ttess.REVIEW_BASE_URL.startswith(
                "https://ttess.tmechsmonitor.org/ttess/reteach/scantron"
            )
        )
        self.assertEqual(ttess.REQUEST_TIMEOUT_SECONDS, 30)


class DestinationCacheTests(unittest.TestCase):
    def test_it_refetches_once_stale(self):
        cache = ttess.DestinationCache()
        with mock.patch.object(ttess, "fetch_destinations", return_value=[{"exam_id": "a"}]) as fetch:
            cache.get("dlk_live_x")
            cache.get("dlk_live_x")
            self.assertEqual(fetch.call_count, 1)
            cache.fetched_at -= ttess.DESTINATION_CACHE_SECONDS + 1
            cache.get("dlk_live_x")
            self.assertEqual(fetch.call_count, 2)

    def test_force_refetches_immediately(self):
        cache = ttess.DestinationCache()
        with mock.patch.object(ttess, "fetch_destinations", return_value=[]) as fetch:
            cache.get("dlk_live_x")
            cache.get("dlk_live_x", force=True)
        self.assertEqual(fetch.call_count, 2)

    def test_the_cache_window_matches_the_specification(self):
        self.assertEqual(ttess.DESTINATION_CACHE_SECONDS, 15 * 60)


if __name__ == "__main__":
    unittest.main()

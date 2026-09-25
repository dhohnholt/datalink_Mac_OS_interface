"""Offline tests for the record parser — no scanner required."""

import json
import tempfile
import time
import unittest
from pathlib import Path

from datalink_scanner.interface import (
    DEFAULT_ANSWER_COUNT,
    EXPECTED_FIELD_COUNT,
    DataLinkError,
    DataLinkFormRecord,
    DataLinkStreamParser,
    append_jsonl,
    describe_message,
)

from support import build_fields, build_line


class FormRecordTests(unittest.TestCase):
    def test_extracts_the_answer_window(self):
        responses = ["A", "B", "C", "D", "E"] * 10
        record = DataLinkFormRecord.from_line(build_line(responses))
        self.assertEqual(record.responses, responses)
        self.assertEqual(len(record.fields), EXPECTED_FIELD_COUNT)

    def test_blank_answers_are_preserved_not_trimmed(self):
        # A form length is chosen up front precisely so trailing blanks stay
        # blank instead of shortening the record.
        responses = ["A"] * 47 + ["", "", ""]
        record = DataLinkFormRecord.from_line(build_line(responses))
        self.assertEqual(len(record.responses), DEFAULT_ANSWER_COUNT)
        self.assertEqual(record.responses[-3:], ["", "", ""])
        self.assertEqual(record.public_dict()["answered_count"], 47)

    def test_multiple_marks_survive_parsing(self):
        responses = ["AC"] + ["B"] * 49
        record = DataLinkFormRecord.from_line(build_line(responses))
        self.assertEqual(record.responses[0], "AC")

    def test_asterisk_is_accepted(self):
        record = DataLinkFormRecord.from_line(build_line(["*"] + ["A"] * 49))
        self.assertEqual(record.responses[0], "*")

    def test_rejects_wrong_field_count(self):
        with self.assertRaises(DataLinkError) as caught:
            DataLinkFormRecord.from_line(b"1,2,3")
        self.assertIn("211", str(caught.exception))

    def test_rejects_unexpected_response_values(self):
        with self.assertRaises(DataLinkError) as caught:
            DataLinkFormRecord.from_line(build_line(["Z"] + ["A"] * 49))
        self.assertIn("Z", str(caught.exception))

    def test_rejects_non_ascii(self):
        line = build_line(["A"] * 50).replace(b"900011", b"\xff\xfe")
        with self.assertRaises(DataLinkError):
            DataLinkFormRecord.from_line(line)

    def test_rejects_out_of_range_question_counts(self):
        for count in (0, -1, 101, 211):
            with self.assertRaises(DataLinkError, msg=count):
                DataLinkFormRecord.from_line(build_line(["A"] * 50), question_count=count)

    def test_rejects_a_non_numeric_question_count(self):
        with self.assertRaises(DataLinkError):
            DataLinkFormRecord.from_line(build_line(["A"] * 50), question_count="many")

    def test_any_count_in_range_is_accepted(self):
        for count in (1, 29, 33, 50, 64, 99, 100):
            record = DataLinkFormRecord.from_line(
                build_line(["A"] * 100), question_count=count
            )
            self.assertEqual(len(record.responses), count, count)

    def test_trailing_blanks_are_preserved_at_any_length(self):
        """The whole point of setting a form length: a student who leaves the
        last questions blank must produce blanks, not a shorter record."""
        for count in (10, 30, 45, 75, 100):
            answered = count // 2
            responses = ["B"] * answered + [""] * (count - answered)
            record = DataLinkFormRecord.from_line(
                build_line(responses), question_count=count
            )
            self.assertEqual(len(record.responses), count, count)
            self.assertEqual(record.responses[answered:], [""] * (count - answered))
            self.assertEqual(record.public_dict()["answered_count"], answered, count)

    def test_a_short_count_does_not_pull_in_neighbouring_fields(self):
        # Answers sit in a fixed window; asking for fewer must simply stop
        # early rather than shift into protocol metadata.
        record = DataLinkFormRecord.from_line(build_line(["C"] * 100), question_count=5)
        self.assertEqual(record.responses, ["C"] * 5)

    def test_question_count_selects_the_window_length(self):
        record = DataLinkFormRecord.from_line(build_line(["A"] * 75), question_count=30)
        self.assertEqual(len(record.responses), 30)


class PublicDictTests(unittest.TestCase):
    def test_omits_the_other_161_fields_by_default(self):
        record = DataLinkFormRecord.from_line(build_line(["A"] * 50))
        public = record.public_dict()
        self.assertNotIn("fields", public)
        self.assertEqual(public["answered_count"], 50)
        self.assertEqual(public["scanner_id"], "900011")

    def test_includes_raw_fields_on_request(self):
        record = DataLinkFormRecord.from_line(build_line(["A"] * 50))
        self.assertEqual(len(record.public_dict(True)["fields"]), EXPECTED_FIELD_COUNT)

    def test_the_scanners_own_marking_is_read_from_field_one(self):
        fields = build_fields(["A"] * 30)
        fields[1] = "024"
        line = ",".join(fields).encode("ascii")
        record = DataLinkFormRecord.from_line(line, question_count=30)
        self.assertEqual(record.public_dict()["scanner_score"], 24)

    def test_a_scanner_with_no_key_reports_zero_not_nothing(self):
        # 000 is what the device sends when it has no key to mark against,
        # and it is indistinguishable from a sheet that scored nothing.
        fields = build_fields(["A"] * 30)
        fields[1] = "000"
        line = ",".join(fields).encode("ascii")
        record = DataLinkFormRecord.from_line(line, question_count=30)
        self.assertEqual(record.public_dict()["scanner_score"], 0)

    def test_a_blank_marking_field_is_not_a_score(self):
        record = DataLinkFormRecord.from_line(build_line(["A"] * 50))
        self.assertIsNone(record.public_dict()["scanner_score"])

    def test_non_numeric_scanner_id_becomes_none(self):
        record = DataLinkFormRecord.from_line(build_line(["A"] * 50, student_id=""))
        self.assertIsNone(record.public_dict()["scanner_id"])


class StreamParserTests(unittest.TestCase):
    def test_separates_control_replies_from_records(self):
        parser = DataLinkStreamParser()
        stream = b"ADV 1200OK\r\n" + build_line(["A"] * 50) + b"\r\n"
        records, messages = parser.feed(stream)
        self.assertEqual(messages, ["ADV 1200OK"])
        self.assertEqual(len(records), 1)

    def test_a_record_split_across_reads_is_reassembled(self):
        parser = DataLinkStreamParser()
        line = build_line(["B"] * 50) + b"\r\n"
        for index in range(0, len(line), 37):
            records, _ = parser.feed(line[index : index + 37])
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0].responses[0], "B")
        self.assertEqual(parser.pending_bytes, b"")

    def test_incomplete_trailing_data_stays_buffered(self):
        parser = DataLinkStreamParser()
        records, messages = parser.feed(b"ADV 12")
        self.assertEqual((records, messages), ([], []))
        self.assertEqual(parser.pending_bytes, b"ADV 12")

    def test_multiple_records_in_one_read(self):
        parser = DataLinkStreamParser(question_count=30)
        stream = (
            build_line(["A"] * 30) + b"\r\n" + build_line(["C"] * 30) + b"\r\n"
        )
        records, _ = parser.feed(stream)
        self.assertEqual([record.responses[0] for record in records], ["A", "C"])

    def test_empty_lines_are_ignored(self):
        parser = DataLinkStreamParser()
        records, messages = parser.feed(b"\r\n\r\nOK\r\n")
        self.assertEqual(records, [])
        self.assertEqual(messages, ["OK"])


class BadLineTests(unittest.TestCase):
    def test_one_unreadable_line_does_not_take_the_rest_of_the_read(self):
        # The bytes are consumed either way and the paper has already gone
        # through the machine, so raising here used to lose good sheets.
        parser = DataLinkStreamParser(question_count=30)
        broken = b",".join([b"x"] * 40)
        stream = (
            build_line(["A"] * 30) + b"\r\n"
            + broken + b"\r\n"
            + build_line(["C"] * 30) + b"\r\n"
        )
        records, messages = parser.feed(stream)
        self.assertEqual([record.responses[0] for record in records], ["A", "C"])
        self.assertTrue(any("Unreadable form record" in item for item in messages))

    def test_a_line_the_scanner_never_finished_is_given_up_on(self):
        parser = DataLinkStreamParser(question_count=30)
        parser.feed(b"D2")
        self.assertIsNone(parser.take_stale_fragment())
        late = time.monotonic() + parser.STALE_FRAGMENT_SECONDS + 1
        self.assertEqual(parser.take_stale_fragment(now=late), "D2")
        self.assertEqual(parser.pending_bytes, b"")

    def test_the_next_record_survives_a_fragment_that_was_dropped(self):
        parser = DataLinkStreamParser(question_count=30)
        parser.feed(b"D2")
        parser.take_stale_fragment(now=time.monotonic() + 10)
        records, _ = parser.feed(build_line(["B"] * 30) + b"\r\n")
        self.assertEqual(len(records), 1)


class DescribeMessageTests(unittest.TestCase):
    def test_command_replies_stay_with_the_protocol_chatter(self):
        self.assertEqual(describe_message("OK")[0], "protocol")
        self.assertEqual(describe_message("ADV 1200OK")[0], "protocol")

    def test_a_side_prompt_is_a_warning_in_plain_words(self):
        kind, text = describe_message("D2")
        self.assertEqual(kind, "warning")
        self.assertIn("side 2", text)
        self.assertIn("Reset scanner", text)

    def test_a_skipped_record_is_not_described_twice(self):
        kind, described = describe_message(
            "Unreadable form record skipped: Expected 211 CSV fields; received 40"
        )
        self.assertEqual(kind, "error")
        self.assertNotIn("unexpected message", described)

    def test_an_unknown_line_is_still_flagged_and_passed_through(self):
        kind, text = describe_message("ZZ9")
        self.assertEqual(kind, "warning")
        self.assertIn("ZZ9", text)


class AppendJsonlTests(unittest.TestCase):
    def test_writes_one_privacy_minimal_object_per_line(self):
        record = DataLinkFormRecord.from_line(build_line(["A"] * 50))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "nested" / "session.jsonl"
            append_jsonl(path, record, include_raw_fields=False, extra={"number": 1})
            append_jsonl(path, record, include_raw_fields=False, extra={"number": 2})
            lines = path.read_text().strip().split("\n")
        self.assertEqual(len(lines), 2)
        first = json.loads(lines[0])
        self.assertEqual(first["number"], 1)
        self.assertNotIn("fields", first)


if __name__ == "__main__":
    unittest.main()

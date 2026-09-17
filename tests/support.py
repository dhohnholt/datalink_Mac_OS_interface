"""Helpers for building synthetic scanner output.

Real captures contain student data, so every test here builds its own
211-field records instead of reading from captures/.
"""

from __future__ import annotations

from datalink_scanner.interface import (
    ANSWER_START,
    EXPECTED_FIELD_COUNT,
)


def build_fields(responses: list[str], student_id: str = "900011") -> list[str]:
    """A 211-field record with `responses` bubbled in the answer window."""
    fields = [""] * EXPECTED_FIELD_COUNT
    fields[0] = student_id
    for offset, value in enumerate(responses):
        fields[ANSWER_START + offset] = value
    return fields


def build_line(responses: list[str], student_id: str = "900011") -> bytes:
    """The same record as the scanner puts it on the wire: CSV, no CRLF."""
    return ",".join(build_fields(responses, student_id)).encode("ascii")

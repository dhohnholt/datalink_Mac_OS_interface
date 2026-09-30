#!/usr/bin/env python3
"""Hash what the Python app makes of a real database, for comparison with Dart.

Usage:  check_realdata.py <copy-of-library.sqlite3>

Prints one line per item -- `<kind> <id> <sha256>` -- and nothing else. The
hashes cover sessions, their scans, the class list, dismissed review items and
the full analysis report (with a fixed run id and clock), so two implementations
that print the same lines have read and scored the data identically.

Run it on a COPY: opening a database migrates it. No student data is printed,
which is why this can be run and shared without exposing any.
"""

from __future__ import annotations

import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src"))

from datalink_scanner.analysis import AnalysisError, build_session_analysis, scan_fingerprint  # noqa: E402
from datalink_scanner.store import Store  # noqa: E402
from datalink_scanner.vendor import result_schema  # noqa: E402

FIXED = datetime(2026, 9, 30, 12, 34, 56, 789012, tzinfo=timezone.utc)
RUN_ID = "00000000-0000-4000-8000-000000000000"


class FixedDatetime(datetime):
    @classmethod
    def now(cls, tz=None):
        return FIXED


result_schema.datetime = FixedDatetime  # type: ignore[attr-defined]


def digest(value) -> str:
    return hashlib.sha256(json.dumps(value).encode("utf-8")).hexdigest()


def main(path: str) -> int:
    store = Store(path)
    print("classes -", digest(store.list_classes()))
    sessions = store.list_sessions()
    print("sessions -", digest(sessions))
    for listed in sorted(sessions, key=lambda item: item["id"]):
        sid = listed["id"]
        session = store.session(sid)
        scans = store.session_scans(sid)
        print("session", sid, digest(session))
        print("scans", sid, digest(scans))
        print("dismissed", sid, digest(sorted(store.dismissed_reviews(sid))))
        print("fingerprint", sid, scan_fingerprint(session, scans))
        try:
            report = build_session_analysis(
                session, scans, run_id=RUN_ID, dismissed=store.dismissed_reviews(sid)
            )
            print("analysis", sid, digest(report))
        except AnalysisError as exc:
            print("analysis", sid, "error", digest(str(exc)))
    store.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1]))

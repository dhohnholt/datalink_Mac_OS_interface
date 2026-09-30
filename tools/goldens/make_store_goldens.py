#!/usr/bin/env python3
"""Differential goldens for the SQLite store.

Each scenario is a list of operations. This script runs them against the real
`datalink_scanner.store.Store` on a deterministic clock and records what every
operation returned (or which error it raised) plus a dump of every table at the
end. The Dart port replays the same operations and must match all of it.

The table schema is compared too, so a database written by one implementation
opens in the other.

Everything is synthetic.

    .venv/bin/python tools/goldens/make_store_goldens.py
"""

from __future__ import annotations

import gzip
import json
import random
import sqlite3
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src"))

from datalink_scanner import store as store_module  # noqa: E402
from datalink_scanner.store import Store  # noqa: E402

OUT = ROOT / "packages" / "datalink_core" / "test" / "goldens" / "store.json.gz"
BASE = datetime(2026, 9, 1, 8, 0, 0, tzinfo=timezone.utc)
TABLES = ["settings", "classes", "students", "sessions", "review_dismissals", "scans"]


class Clock:
    """One tick per call, so both implementations can be made to agree on
    exactly how many times the clock is read."""

    def __init__(self) -> None:
        self.ticks = 0
        self.offset = timedelta(0)

    def now(self, tz=None):
        stamp = BASE + timedelta(seconds=self.ticks) + self.offset
        self.ticks += 1
        return stamp


class FakeDatetime:
    clock: Clock

    @classmethod
    def now(cls, tz=None):
        return cls.clock.now(tz)


def normalize(value):
    if isinstance(value, (set, frozenset)):
        return sorted(value)
    if isinstance(value, tuple):
        return [normalize(item) for item in value]
    if isinstance(value, list):
        return [normalize(item) for item in value]
    if isinstance(value, dict):
        return {key: normalize(item) for key, item in value.items()}
    return value


def apply(store: Store, clock: Clock, op: dict):
    name, a = op["op"], op.get("args", {})
    if name == "set_setting":
        return store.set_setting(a["key"], a["value"])
    if name == "get_setting":
        return store.get_setting(a["key"], a.get("default", ""))
    if name == "save_class":
        return store.save_class(a["name"], a["students"], a.get("original_name"))
    if name == "delete_class":
        return store.delete_class(a["name"])
    if name == "list_classes":
        return store.list_classes()
    if name == "get_class":
        return store.get_class(a["name"])
    if name == "create_session":
        return store.create_session(
            a["name"], a["class_name"], a["question_count"],
            log_path=a.get("log_path"), source=a.get("source", "datalink"),
            page_cache=a.get("page_cache"),
        )
    if name == "update_session":
        return store.update_session(
            a["id"], name=a.get("name"), class_name=a.get("class_name"),
            finished=a.get("finished", False),
        )
    if name == "remember_run_id":
        return store.remember_run_id(a["id"], a["run_id"], a["fingerprint"])
    if name == "add_scan":
        return store.add_scan(a["session_id"], a["scan"])
    if name == "update_scan":
        return store.update_scan(
            a["session_id"], a["number"], student_id=a.get("student_id"),
            student_name=a.get("student_name"), responses=a.get("responses"),
        )
    if name == "apply_corrections":
        return store.apply_corrections(a["session_id"], a["corrections"], a["dismiss"])
    if name == "list_sessions":
        return store.list_sessions()
    if name == "session":
        return store.session(a["id"])
    if name == "name_missing_students":
        return store.name_missing_students(a["id"])
    if name == "session_scans":
        return store.session_scans(a["id"])
    if name == "delete_session":
        return store.delete_session(a["id"])
    if name == "dismissed_reviews":
        return store.dismissed_reviews(a["id"])
    if name == "dismiss_reviews":
        return store.dismiss_reviews(a["id"], a["keys"])
    if name == "restore_reviews":
        return store.restore_reviews(a["id"])
    if name == "prune_empty_sessions":
        return store.prune_empty_sessions(a.get("session_id"))
    if name == "sessions_older_than":
        return store.sessions_older_than(a["days"])
    if name == "delete_sessions":
        return store.delete_sessions(a["ids"])
    if name == "vacuum":
        return store.vacuum()
    if name == "advance":
        clock.offset += timedelta(days=a["days"])
        return None
    raise AssertionError(name)


def dump(path: str) -> dict:
    connection = sqlite3.connect(path)
    connection.row_factory = sqlite3.Row
    out = {"tables": {}, "schema": {}, "indexes": []}
    for table in TABLES:
        rows = connection.execute(f"SELECT * FROM {table} ORDER BY id" if table != "settings"
                                  else "SELECT * FROM settings ORDER BY key").fetchall()
        out["tables"][table] = [dict(row) for row in rows]
        out["schema"][table] = [
            [r["name"], r["type"], r["notnull"], r["dflt_value"], r["pk"]]
            for r in connection.execute(f"PRAGMA table_info({table})")
        ]
    out["indexes"] = sorted(
        r["name"] for r in connection.execute(
            "SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%'"
        )
    )
    connection.close()
    return out


def run_scenario(name: str, ops: list[dict]) -> dict:
    clock = Clock()
    FakeDatetime.clock = clock
    store_module.datetime = FakeDatetime  # type: ignore[attr-defined]
    with tempfile.TemporaryDirectory() as directory:
        path = str(Path(directory) / "library.sqlite3")
        store = Store(path)
        results = []
        for op in ops:
            try:
                results.append({"ok": normalize(apply(store, clock, op))})
            except ValueError as exc:
                results.append({"error": str(exc)})
            except sqlite3.Error:
                results.append({"db_error": True})
        store.close()
        return {"name": name, "ops": ops, "results": results, "dump": dump(path)}


# ---------------------------------------------------------------------- helpers


def op(_op, /, **args):
    return {"op": _op, "args": args}


def student(id_, name):
    return {"id": id_, "name": name}


def scan(number, role="student", responses=None, **extra):
    responses = responses if responses is not None else ["A", "B", "C"]
    row = {"number": number, "role": role, "student_id": None, "student_name": None,
           "received_at": f"2026-09-16T18:{number:02d}:00+00:00",
           "answered_count": sum(1 for v in responses if v), "responses": responses,
           "demo": False}
    row.update(extra)
    return row


def fixed_scenarios() -> list[tuple[str, list[dict]]]:
    roster = [student("900011", "Ada"), student("900012", "Bo"), student("900013", "Cy")]
    s = []
    s.append(("classes: round trip, replace, rename, errors", [
        op("save_class", name="Period 4", students=roster),
        op("list_classes"),
        op("save_class", name="Period 4", students=[student("900011", "Ada")]),
        op("get_class", name="Period 4"),
        op("save_class", name="Period 5", students=roster, original_name="Period 4"),
        op("list_classes"),
        op("save_class", name="period 5", students=roster),          # duplicate, any case
        op("save_class", name="Econ", students=roster),
        op("save_class", name="ECON", students=roster, original_name="Econ"),  # same class, new case
        op("save_class", name="Econ", students=roster, original_name="Period 5"),  # rename onto another
        op("save_class", name="   ", students=roster),
        op("save_class", name="X", students=[student("900011", "A"), student("900011", "B")]),
        op("save_class", name="X", students=[student("abc", "A")]),
        op("save_class", name="X", students=[student("900011", "  ")]),
        op("save_class", name="  Spaced  ", students=[student(" 900011 ", " Padded ")]),
        op("list_classes"),
        op("delete_class", name="Spaced"),
        op("delete_class", name="nonexistent"),
        op("list_classes"),
    ]))
    s.append(("classes: listed alphabetically, ignoring case", [
        op("save_class", name=name, students=roster) for name in ["beta", "Alpha", "gamma", "Beta2", "alpha2"]
    ] + [op("list_classes")]))
    s.append(("settings", [
        op("get_setting", key="nope"),
        op("get_setting", key="nope", default="fallback"),
        op("set_setting", key="test_name", value="Unit 1"),
        op("get_setting", key="test_name"),
        op("set_setting", key="test_name", value="Unit 2"),
        op("get_setting", key="test_name", default="x"),
        op("set_setting", key="empty", value=""),
        op("get_setting", key="empty", default="d"),
    ]))
    s.append(("sessions: scans round trip, listing, delete, prune", [
        op("create_session", name="First", class_name="P4", question_count=3),
        op("create_session", name="Second", class_name="", question_count=50, source="paper",
           page_cache="/tmp/cache/abc", log_path="/tmp/x.jsonl"),
        op("create_session", name="Empty", class_name="", question_count=5, source=""),
        op("add_scan", session_id=1, scan=scan(1, "key", ["A", "B", "C"])),
        op("add_scan", session_id=1, scan=scan(2, responses=["A", "", "AC"], student_id="900011",
                                                student_name="Ada", demo=True)),
        op("add_scan", session_id=1, scan={"number": 3, "responses": ["*"]}),
        op("add_scan", session_id=2, scan=scan(2, confidence={"1": {"mark_strength": 0.29, "margin": 0.1, "needs_review": False}},
                                                pending_review=1, scanner_score=24)),
        op("add_scan", session_id=99, scan=scan(1)),                 # no such session
        op("session_scans", id=1),
        op("session_scans", id=2),
        op("session_scans", id=3),
        op("list_sessions"),
        op("session", id=1),
        op("session", id=404),
        op("update_session", id=1, name="Renamed"),
        op("update_session", id=1, class_name="P5", finished=True),
        op("update_session", id=1),
        op("session", id=1),
        op("prune_empty_sessions", session_id=1),
        op("prune_empty_sessions"),
        op("list_sessions"),
        op("delete_session", id=1),
        op("list_sessions"),
        op("session_scans", id=1),
    ]))
    s.append(("corrections: in place, recount, unknown sheet, empty, batch", [
        op("create_session", name="T", class_name="", question_count=3),
        op("add_scan", session_id=1, scan=scan(1, "key", ["A", "B", "C"])),
        op("add_scan", session_id=1, scan=scan(2, student_id="900011", pending_review=1)),
        op("update_scan", session_id=1, number=2, student_id="900099"),
        op("update_scan", session_id=1, number=2, student_name="New Name", responses=["A", "A", "A"]),
        op("update_scan", session_id=1, number=2, student_id=""),
        op("update_scan", session_id=1, number=2, responses=["", "", ""]),
        op("update_scan", session_id=1, number=99, student_id="1"),
        op("update_scan", session_id=1, number=2),
        op("session_scans", id=1),
        op("apply_corrections", session_id=1, dismiss=["2:answer:1:faint", "  ", "2:student_id:0:"],
           corrections=[{"number": 2, "student_id": "900011", "student_name": None, "responses": ["B", "B", "B"]}]),
        op("dismissed_reviews", id=1),
        op("apply_corrections", session_id=1, dismiss=["9:x:0:"],
           corrections=[{"number": 404, "student_id": "1", "student_name": None, "responses": None}]),
        op("dismissed_reviews", id=1),
        op("apply_corrections", session_id=1, dismiss=["only-a-dismissal"], corrections=[]),
        op("session_scans", id=1),
    ]))
    s.append(("naming: roster arrives later, leading zeros, key never named", [
        op("create_session", name="T", class_name="P4", question_count=3),
        op("add_scan", session_id=1, scan=scan(1, "key", ["A", "B", "C"], student_id="900011")),
        op("add_scan", session_id=1, scan=scan(2, student_id="900011")),
        op("add_scan", session_id=1, scan=scan(3, student_id="0900012")),
        op("add_scan", session_id=1, scan=scan(4, student_id="900099")),
        op("add_scan", session_id=1, scan=scan(5, student_id="900013", student_name="Typed")),
        op("add_scan", session_id=1, scan=scan(6, student_id="")),
        op("name_missing_students", id=1),
        op("save_class", name="P4", students=[student("900011", "Ada"), student("00900012", "Bo"),
                                               student("900013", "Cy")]),
        op("name_missing_students", id=1),
        op("name_missing_students", id=1),
        op("session_scans", id=1),
        op("create_session", name="NoClass", class_name="", question_count=3),
        op("add_scan", session_id=2, scan=scan(2, student_id="900011")),
        op("name_missing_students", id=2),
        op("name_missing_students", id=77),
        op("save_class", name="P4", students=[student("0", "Zero")]),
        op("name_missing_students", id=1),
    ]))
    s.append(("class rename carries through to sessions", [
        op("save_class", name="Old", students=roster),
        op("create_session", name="A", class_name="Old", question_count=3),
        op("create_session", name="B", class_name="Other", question_count=3),
        op("save_class", name="New", students=roster, original_name="Old"),
        op("list_sessions"),
        op("save_class", name="New", students=roster[:1], original_name="New"),
        op("list_sessions"),
    ]))
    s.append(("dismissals: idempotent, blank keys, isolation, cascade", [
        op("create_session", name="A", class_name="", question_count=3),
        op("create_session", name="B", class_name="", question_count=3),
        op("dismissed_reviews", id=1),
        op("dismiss_reviews", id=1, keys=["1:a:0:", "1:a:0:", "2:b:3:faint"]),
        op("dismiss_reviews", id=1, keys=["1:a:0:"]),
        op("dismiss_reviews", id=1, keys=["", "   "]),
        op("dismiss_reviews", id=2, keys=["1:a:0:"]),
        op("dismissed_reviews", id=1),
        op("dismissed_reviews", id=2),
        op("restore_reviews", id=1),
        op("dismissed_reviews", id=1),
        op("dismiss_reviews", id=1, keys=["x"]),
        op("delete_session", id=1),
        op("dismissed_reviews", id=1),
        op("dismiss_reviews", id=404, keys=["x"]),
    ]))
    s.append(("storage: old sessions, bulk delete, vacuum", [
        op("create_session", name="Old", class_name="", question_count=3),
        op("create_session", name="Older", class_name="", question_count=3, log_path="/tmp/a.jsonl"),
        op("advance", days=40),
        op("create_session", name="Recent", class_name="", question_count=3),
        op("sessions_older_than", days=30),
        op("sessions_older_than", days=0),
        op("sessions_older_than", days=365),
        op("sessions_older_than", days=-1),
        op("delete_sessions", ids=[]),
        op("delete_sessions", ids=[1, 2, 999]),
        op("vacuum"),
        op("list_sessions"),
    ]))
    return s


# ---------------------------------------------------------------------- random


def random_scenarios(rng: random.Random, count: int) -> list[tuple[str, list[dict]]]:
    out = []
    names = ["Period 4", "period 4", "Econ", "Govt", "A", "b", "  Padded  ", "Ünï", ""]
    for index in range(count):
        ops: list[dict] = []
        sessions: list[int] = []
        next_session = 1
        scan_numbers: dict[int, list[int]] = {}
        for _ in range(rng.randint(30, 90)):
            roll = rng.random()
            sid = rng.choice(sessions) if sessions and rng.random() < 0.9 else rng.choice([404, 0])
            if roll < 0.10:
                roster = [student(str(900000 + i), rng.choice(["Ada", "Bo", " Cy ", "Dé", "Ed"]))
                          for i in rng.sample(range(40), rng.randint(0, 6))]
                if rng.random() < 0.15:
                    roster.append(rng.choice([student("x1", "Bad"), student("900001", ""), student("0", "Z")]))
                if rng.random() < 0.1 and roster:
                    roster.append(dict(roster[0]))
                ops.append(op("save_class", name=rng.choice(names), students=roster,
                              original_name=rng.choice([None, None, rng.choice(names)])))
            elif roll < 0.13:
                ops.append(op("delete_class", name=rng.choice(names)))
            elif roll < 0.16:
                ops.append(op("set_setting", key=rng.choice(["test_name", "selected_class", "q"]),
                              value=rng.choice(["", "x", "Unit 1"])))
            elif roll < 0.18:
                ops.append(op("get_setting", key=rng.choice(["test_name", "selected_class", "q", "z"]),
                              default=rng.choice(["", "d"])))
            elif roll < 0.26:
                ops.append(op("create_session", name=rng.choice(["", "Unit 1", "Quiz"]),
                              class_name=rng.choice(names), question_count=rng.choice([3, 5, 50]),
                              source=rng.choice(["datalink", "paper", ""]),
                              log_path=rng.choice([None, "/tmp/x.jsonl"]),
                              page_cache=rng.choice([None, "/tmp/c"])))
                sessions.append(next_session)
                scan_numbers[next_session] = []
                next_session += 1
            elif roll < 0.50:
                number = rng.choice([1, 2, 3, 4, 5, 6, 7, 2])
                qc = rng.choice([3, 5])
                responses = [rng.choice(["A", "B", "", "AC", "*", "E"]) for _ in range(qc)]
                row = scan(number, rng.choice(["student", "student", "key"]), responses,
                           student_id=rng.choice([None, "", "900001", "0900002", "900003", "x"]),
                           student_name=rng.choice([None, "", "Ada", "Bo"]),
                           demo=rng.random() < 0.1,
                           pending_review=1 if rng.random() < 0.15 else 0,
                           scanner_score=rng.choice([None, None, 0, 3]))
                if rng.random() < 0.3:
                    row["confidence"] = {str(q): {"mark_strength": round(rng.random(), 4),
                                                  "margin": 0.1, "needs_review": rng.random() < 0.2}
                                         for q in range(1, qc + 1)}
                if rng.random() < 0.1:
                    del row["received_at"]
                if rng.random() < 0.05:
                    row.pop("role")
                ops.append(op("add_scan", session_id=sid, scan=row))
                if sid in scan_numbers:
                    scan_numbers[sid].append(number)
            elif roll < 0.58:
                ops.append(op("update_scan", session_id=sid, number=rng.choice([1, 2, 3, 99]),
                              student_id=rng.choice([None, "", "900009"]),
                              student_name=rng.choice([None, "", "New"]),
                              responses=rng.choice([None, ["A", "B", "C"], ["", "", ""]])))
            elif roll < 0.63:
                corrections = [
                    {"number": rng.choice([1, 2, 3, 99]), "student_id": rng.choice([None, "900008"]),
                     "student_name": rng.choice([None, "Fixed"]),
                     "responses": rng.choice([None, ["B", "B", "B"]])}
                    for _ in range(rng.randint(0, 3))
                ]
                ops.append(op("apply_corrections", session_id=sid, corrections=corrections,
                              dismiss=rng.choice([[], ["k1"], ["k1", "k2", " "]])))
            elif roll < 0.68:
                ops.append(op("update_session", id=sid, name=rng.choice([None, "Renamed"]),
                              class_name=rng.choice([None, "Econ"]), finished=rng.random() < 0.3))
            elif roll < 0.71:
                ops.append(op("remember_run_id", id=sid, run_id="run-1", fingerprint="fp"))
            elif roll < 0.76:
                ops.append(op("name_missing_students", id=sid))
            elif roll < 0.80:
                ops.append(op("dismiss_reviews", id=sid, keys=rng.choice([["a"], ["a", "b"], [], [""]])))
            elif roll < 0.82:
                ops.append(op("restore_reviews", id=sid))
            elif roll < 0.85:
                ops.append(op("prune_empty_sessions", session_id=rng.choice([None, sid])))
            elif roll < 0.88:
                ops.append(op("delete_session", id=sid))
            elif roll < 0.90:
                ops.append(op("delete_sessions", ids=rng.sample(range(1, 6), rng.randint(0, 3))))
            elif roll < 0.92:
                ops.append(op("advance", days=rng.choice([1, 10, 40])))
            elif roll < 0.94:
                ops.append(op("sessions_older_than", days=rng.choice([0, 1, 30])))
            else:
                ops.append(op(rng.choice(["list_sessions", "session", "session_scans", "list_classes",
                                          "dismissed_reviews"]), id=sid))
        ops += [op("list_sessions"), op("list_classes")] + [
            op("session_scans", id=i) for i in sessions[:4]
        ]
        out.append((f"random {index}", ops))
    return out


def main() -> int:
    rng = random.Random(20260930)
    scenarios = fixed_scenarios() + random_scenarios(rng, 60)
    golden = {
        "note": "Generated by tools/goldens/make_store_goldens.py from store.py. Synthetic data only.",
        "python": sys.version.split()[0],
        "sqlite": sqlite3.sqlite_version,
        "base": BASE.isoformat(),
        "scenarios": [run_scenario(name, ops) for name, ops in scenarios],
    }
    raw = (json.dumps(golden, ensure_ascii=True) + "\n").encode("ascii")
    OUT.write_bytes(gzip.compress(raw, compresslevel=9, mtime=0))
    print(f"wrote {OUT.relative_to(ROOT)} ({OUT.stat().st_size // 1024} KB gzipped, {len(raw) // 1024} KB raw)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

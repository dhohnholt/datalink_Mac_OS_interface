#!/usr/bin/env python3
"""Generate the scoring and analysis golden files from the real Python code.

Two things are recorded for the Dart port (`packages/datalink_core`):

* the numeric primitives the scoring leans on -- `round`, float `sum`, and the
  `statistics` functions -- because each behaves in a specific way that a
  straightforward translation gets subtly wrong;
* whole analysis reports from `analysis.build_session_analysis`, as the exact
  `json.dumps` text, so key order and int-versus-float are checked as well.

Every session is synthetic and seeded. IDs are invented; nothing comes from
`captures/` or from the real database.

    .venv/bin/python tools/goldens/make_analysis_goldens.py
"""

from __future__ import annotations

import gzip
import json
import random
import statistics
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src"))

from datalink_scanner import analysis  # noqa: E402
from datalink_scanner.analysis import AnalysisError, build_session_analysis  # noqa: E402
from datalink_scanner.vendor import result_schema  # noqa: E402

OUT = ROOT / "packages" / "datalink_core" / "test" / "goldens" / "analysis.json.gz"

FIXED_NOW = datetime(2026, 9, 30, 12, 34, 56, 789012, tzinfo=timezone.utc)
RUN_ID = "00000000-0000-4000-8000-000000000000"


class FixedDatetime(datetime):
    @classmethod
    def now(cls, tz=None):  # noqa: D401
        return FIXED_NOW


result_schema.datetime = FixedDatetime  # type: ignore[attr-defined]


# ------------------------------------------------------------------------ math


def kind(value) -> str:
    return "int" if isinstance(value, int) and not isinstance(value, bool) else "float"


def math_cases(rng: random.Random) -> dict:
    rounds = []
    tricky = [0.5, 1.5, 2.5, 2.675, 0.125, 0.375, 1.005, 73.35, 66.65, 0.285, 1.45, 8.345, 0.0005, 0.00049999999]
    values = list(tricky)
    for _ in range(400):
        correct, total = rng.randint(0, 100), rng.randint(1, 100)
        values.append(min(correct, total) / total * 100)
    for _ in range(200):
        values.append(rng.random() * rng.choice([1, 10, 100, 1000]))
    for _ in range(40):
        values.append(-rng.random() * 10)
    values += [0.0, -0.0, 1e-9, 12345.6789, 5e-324, 1e15 + 0.5]
    for value in values:
        for digits in (1, 2, 3, 4):
            rounds.append({"x": value, "digits": digits, "result": round(value, digits)})

    round_ints = []
    for value in [0.5, 1.5, 2.5, 3.5, 4.5, 13.5, 12.5, 0.49999999999999994, 2.6999999999999997]:
        round_ints.append({"x": value, "result": round(value)})
    for n in range(0, 200):
        value = n * 0.27
        round_ints.append({"x": value, "result": round(value)})

    sums = []
    float_lists = [
        [0.1] * 10, [0.1] * 3, [1e16, 1.0, -1e16], [0.1, 0.2, 0.3], [0.7, 0.1, 0.1],
        [1.0], [0.25], [0.1, 0.2],
    ]
    for _ in range(120):
        count = rng.randint(1, 100)
        float_lists.append([
            (d := rng.randint(0, 100) / 100) * (1 - d) for _ in range(count)
        ])
    for values in float_lists:
        sums.append({"values": values, "result": sum(values)})

    stats = []
    int_lists = [
        [1], [1, 2], [2, 4], [1, 2, 3, 4], [5, 5, 5], [0, 0, 1], [3, 1, 2],
        [22, 25, 16, 18, 15, 12, 27, 16, 17, 15, 7, 25, 21, 29, 6],
    ]
    for _ in range(300):
        size = rng.randint(1, 60)
        top = rng.choice([5, 10, 30, 50, 100])
        int_lists.append([rng.randint(0, top) for _ in range(size)])
    for data in int_lists:
        entry = {"data": data}
        entry["mean"] = {"v": statistics.mean(data)}
        entry["mean"]["type"] = kind(entry["mean"]["v"])
        entry["median"] = {"v": statistics.median(data)}
        entry["median"]["type"] = kind(entry["median"]["v"])
        if len(data) > 1:
            entry["variance"] = {"v": statistics.variance(data)}
            entry["variance"]["type"] = kind(entry["variance"]["v"])
            entry["stdev"] = {"v": statistics.stdev(data), "type": "float"}
        stats.append(entry)
    return {"round": rounds, "round_int": round_ints, "sum": sums, "stats": stats}


# -------------------------------------------------------------------- sessions


NAMES = ["Ada Lovelace", "José Peña", "  Mary  ", "O'Brien", "张伟", "Zoë", "", None]
LETTERS = "ABCDE"


def make_session(rng: random.Random, index: int) -> dict:
    question_count = rng.choice([1, 2, 3, 5, 10, 20, 30, 50, 50, 100])
    source = rng.choice(["datalink", "datalink", "paper"])
    session = {
        "id": index,
        "name": rng.choice(["Unit 1", "", "Quiz: Ünïcode", "a/b.csv", "Period 4 - Test"]),
        "class_name": rng.choice(["Period 4", "", "Econ"]),
        "question_count": question_count,
        "started_at": "2026-09-16T18:00:00+00:00",
        "ended_at": None,
        "log_path": rng.choice([None, None, "/x/y/browser_session_20260916_120450.jsonl"]),
        "source": source,
    }
    if rng.random() < 0.03:
        session["question_count"] = 0

    key_answers = [rng.choice(LETTERS) for _ in range(question_count)]
    if rng.random() < 0.08:
        key_answers[rng.randrange(question_count)] = rng.choice(["", "AC", "*"])
    if rng.random() < 0.02:
        key_answers[rng.randrange(question_count)] = "Z"

    device_has_key = rng.random() < 0.6
    stale_key = device_has_key and rng.random() < 0.15

    def scan(number, role, responses, **extra):
        row = {
            "number": number, "role": role, "student_id": None, "student_name": None,
            "received_at": "2026-09-16T18:00:00+00:00",
            "answered_count": sum(1 for v in responses if v),
            "responses": responses, "demo": False, "confidence": {}, "pending_review": 0,
            "scanner_score": None,
        }
        row.update(extra)
        return row

    key_score = None
    if session["source"] == "datalink" and device_has_key:
        key_score = question_count - 1 if stale_key else question_count
    scans = []
    roles = rng.random()
    if roles > 0.03:
        scans.append(scan(rng.choice([1, 1, 1, 5]), "key", key_answers, scanner_score=key_score))
    if roles < 0.03 or rng.random() < 0.03:
        scans.append(scan(9, "key", key_answers))

    count = rng.choice([0, 1, 2, 3, 5, 9, 10, 11, 14, 18, 25])
    ability = rng.random()
    used_ids = set()
    for i in range(count):
        correct_chance = min(0.98, max(0.05, ability + rng.uniform(-0.3, 0.3)))
        responses = []
        for q in range(question_count):
            roll = rng.random()
            if roll < 0.04:
                responses.append("")
            elif roll < 0.06:
                responses.append(rng.choice(["AC", "*", "BD", "ABC"]))
            elif rng.random() < correct_chance:
                responses.append(key_answers[q] if key_answers[q] in LETTERS else "A")
            else:
                responses.append(rng.choice(LETTERS))
        if rng.random() < 0.1 and question_count > 2:
            responses = responses[: rng.randrange(1, question_count)]
        student_id = rng.choice([
            str(900000 + rng.randrange(100)), str(900000 + rng.randrange(100)),
            "", None, "  900011 ", "AB12", "0900011",
        ])
        confidence = {}
        if session["source"] == "paper":
            base = rng.choice([0.29, 0.29, 0.06])
            for q in range(1, question_count + 1):
                if rng.random() < 0.85:
                    strength = round(max(0.0, rng.gauss(base, 0.08)), 4)
                    confidence[str(q)] = {
                        "mark_strength": strength,
                        "margin": round(strength / 2, 4),
                        "needs_review": strength < 0.05,
                    }
        scanner_score = None
        if session["source"] == "datalink" and device_has_key:
            truth = sum(
                1 for q, given in enumerate(responses)
                if q < len(key_answers) and given == key_answers[q]
            )
            scanner_score = truth if rng.random() < 0.85 else max(0, truth - 1)
        elif session["source"] == "datalink" and rng.random() < 0.5:
            scanner_score = 0
        number = rng.choice([i + 2, i + 2, i + 2, 2, 0])
        scans.append(scan(
            number, "student", responses,
            student_id=student_id, student_name=rng.choice(NAMES),
            confidence=confidence, pending_review=1 if rng.random() < 0.05 else 0,
            scanner_score=scanner_score,
        ))
    rng.shuffle(scans) if rng.random() < 0.2 else None
    return {"session": session, "scans": scans}


def run_case(case: dict, dismissed=frozenset(), exam_name=None) -> dict:
    entry = {"dismissed": sorted(dismissed), "exam_name": exam_name}
    try:
        report = build_session_analysis(
            case["session"], case["scans"], exam_name=exam_name,
            run_id=RUN_ID, dismissed=dismissed,
        )
        entry["json"] = json.dumps(report)
    except AnalysisError as exc:
        entry["error"] = str(exc)
    return entry


def session_cases(rng: random.Random, total: int) -> list[dict]:
    cases = []
    for index in range(1, total + 1):
        case = make_session(rng, index)
        runs = [run_case(case, exam_name=rng.choice([None, None, "Custom name", ""]))]
        # Settle some of the review items and score again.
        if "json" in runs[0]:
            items = json.loads(runs[0]["json"])["review_items"]
            if items:
                chosen = {
                    analysis.review_key(item)
                    for item in items if rng.random() < 0.5
                }
                runs.append(run_case(case, dismissed=frozenset(chosen)))
        cases.append({
            "session": case["session"],
            "scans": case["scans"],
            "fingerprint": analysis.scan_fingerprint(case["session"], case["scans"]),
            "runs": runs,
        })
    return cases


def fixed_cases() -> list[dict]:
    """The scenarios in tests/test_analysis.py, by hand."""
    def session(question_count=5, name="Unit 1", log_path=None):
        return {"id": 1, "name": name, "class_name": "Period 4",
                "question_count": question_count,
                "started_at": "2026-09-16T18:00:00+00:00", "ended_at": None,
                "log_path": log_path}

    def scan(number, role, responses, student_id=None, student_name=None, **extra):
        row = {"number": number, "role": role, "student_id": student_id,
               "student_name": student_name,
               "received_at": "2026-09-16T18:00:00+00:00",
               "answered_count": sum(1 for v in responses if v),
               "responses": responses, "demo": False}
        row.update(extra)
        return row

    cases = [
        {"session": session(), "scans": [
            scan(1, "key", ["A", "B", "C", "D", "E"]),
            scan(2, "student", ["A", "B", "C", "D", "E"], "900011", "All right"),
            scan(3, "student", ["A", "B", "C", "E", ""], "900012", "Two wrong")]},
        {"session": session(), "scans": [
            scan(1, "key", ["A"] * 5), scan(2, "student", ["A", "A"], "900011")]},
        {"session": session(), "scans": [
            scan(1, "key", ["A"] * 5),
            scan(2, "student", ["A", "AC", "A", "A", "A"], "900011")]},
        {"session": session(), "scans": [scan(2, "student", ["A"] * 5, "900011")]},
        {"session": session(), "scans": [
            scan(1, "key", ["A"] * 5), scan(2, "key", ["A"] * 5),
            scan(3, "student", ["A"] * 5, "900011")]},
        {"session": session(), "scans": [scan(1, "key", ["A"] * 5)]},
        {"session": session(), "scans": [
            scan(1, "key", ["A", "", "C", "D", "E"]),
            scan(2, "student", ["A"] * 5, "900011")]},
        {"session": session(), "scans": [
            scan(1, "key", ["A", "Z", "C", "D", "E"]),
            scan(2, "student", ["A"] * 5, "900011")]},
        {"session": session(question_count=0), "scans": [
            scan(1, "key", ["A"]), scan(2, "student", ["A"], "900011")]},
    ]
    # The device's own marking: agreeing, disagreeing, no key, stale key.
    def scored(key_score, scores, truth_override=None):
        key = ["A", "B", "C", "D", "E"]
        rows = [scan(1, "key", key, scanner_score=key_score)]
        answers = [["A", "B", "C", "D", "E"], ["A", "B", "C", "E", ""], ["E"] * 5]
        for i, (given, score) in enumerate(zip(answers, scores)):
            rows.append(scan(i + 2, "student", given, f"90001{i}", f"S{i}", scanner_score=score))
        return {"session": session(), "scans": rows}

    cases += [scored(5, [5, 3, 0]), scored(5, [5, 4, 0]), scored(0, [0, 0, 0]),
              scored(4, [5, 3, 0]), scored(None, [None, None, None])]
    out = []
    for case in cases:
        out.append({
            "session": case["session"], "scans": case["scans"],
            "fingerprint": analysis.scan_fingerprint(case["session"], case["scans"]),
            "runs": [run_case(case)],
        })
    return out


def filename_cases() -> list[dict]:
    from datalink_scanner.server import records_to_csv, safe_export_filename

    names = ["Unit 1", "", "  ", "a/b", "Quiz: Ünïcode", "x.csv", "X.CSV", "...", " . ",
             "weird\tname\n", "日本語", "a.b.c", "ok-name_1.0", "con", "a" * 300]
    files = [{"name": n, "result": safe_export_filename(n)} for n in names]

    rows = [
        {"number": 1, "role": "key", "student_id": None, "student_name": None,
         "received_at": "2026-09-16T18:00:00+00:00", "answered_count": 3, "responses": ["A", "", "C"]},
        {"number": 2, "role": "student", "student_id": "900011", "student_name": 'O"Brien, Jr.',
         "received_at": "2026-09-16T18:01:00+00:00", "answered_count": 2, "responses": ["A", "AC", ""]},
        {"number": 3, "student_id": "", "student_name": "Zoë\nNewline",
         "received_at": "x", "answered_count": 0, "responses": ["*", "", "", "B"]},
    ]
    csvs = []
    for records, class_name, fallback in [
        ([], "", 50), ([], "Period 4", 3), (rows, "Period 4", 50), (rows[:1], 'Cl,ass "x"', 1),
    ]:
        csvs.append({
            "records": records, "class_name": class_name, "fallback": fallback,
            "result": records_to_csv(records, class_name, fallback).decode("utf-8"),
        })
    return [files, csvs]


def main() -> int:
    rng = random.Random(20260930)
    filenames, csvs = filename_cases()
    golden = {
        "note": "Generated by tools/goldens/make_analysis_goldens.py from the "
                "Python implementation. Synthetic data only.",
        "python": sys.version.split()[0],
        "run_id": RUN_ID,
        "created_at": FIXED_NOW.isoformat(),
        "math": math_cases(rng),
        "fixed": fixed_cases(),
        "random": session_cases(rng, 160),
        "filenames": filenames,
        "csv": csvs,
    }
    # Compressed with a fixed timestamp so regenerating gives identical bytes.
    raw = (json.dumps(golden, ensure_ascii=True) + "\n").encode("ascii")
    OUT.write_bytes(gzip.compress(raw, compresslevel=9, mtime=0))
    size = OUT.stat().st_size / 1024
    print(f"wrote {OUT.relative_to(ROOT)} ({size:.0f} KB gzipped, {len(raw) / 1024:.0f} KB raw)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

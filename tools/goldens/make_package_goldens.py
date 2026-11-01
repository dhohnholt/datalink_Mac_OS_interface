#!/usr/bin/env python3
"""Generate the test-package golden from the real Python code.

Seeded synthetic batches, scored by the vendored omr `version_package.py`;
`packages/datalink_core/test/test_package_test.dart` replays them through the
Dart port. Nothing here comes from a real scan.

    .venv/bin/python tools/goldens/make_package_goldens.py
"""

import json
import random
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VENDOR = ROOT / "src" / "datalink_scanner" / "vendor"
sys.path[:0] = [str(VENDOR / "omr"), str(VENDOR)]

import version_package  # noqa: E402

OUT = ROOT / "packages" / "datalink_core" / "test" / "goldens" / "package.json"


def make_case(rng, index):
    versions = ["1", "2"] if rng.random() < 0.7 else ["1", "2", "3"]
    count = rng.choice([5, 12, 20, 35])
    items = [f"item-{index}-{i}" for i in range(count)]
    numbers = {v: dict(zip(items, rng.sample(range(1, count + 1), count))) for v in versions}
    answers = {
        v: {i: (rng.choice("ABCDE") if rng.random() > 0.1 else "".join(sorted(rng.sample("ABCDE", 2))))
            for i in items}
        for v in versions
    }
    sections = {i: rng.choice(["Part 1", "Part 2", ""]) for i in items}
    standards = {i: rng.choice(["S.1", "S.2", "S.3", ""]) for i in items}
    with_answers = rng.random() < 0.8
    lines = ["Stable item ID,Section,Standard," + ",".join(
        f"Version {v}" + (f",Version {v} answer" if with_answers else "") for v in versions)]
    for i in items:
        cells = [i, sections[i], standards[i]]
        for v in versions:
            cells.append(str(numbers[v][i]))
            if with_answers:
                cells.append(answers[v][i])
        lines.append(",".join(cells))
    text = "\n".join(lines) + "\n"

    sheets = {}
    page = 1
    keys_on_paper = (not with_answers) or rng.random() < 0.5
    if keys_on_paper:
        for v in versions:
            responses = {numbers[v][i]: answers[v][i] for i in items}
            if with_answers and rng.random() < 0.3:
                q = numbers[v][items[0]]
                responses[q] = "A" if responses[q] != "A" else "B"
            sheets[page] = {"version": v, "is_key": True, "student_id": None, "answers": {
                q: ("MULTIPLE" if len(a) > 1 else a) for q, a in responses.items()},
                "marks": {q: a for q, a in responses.items() if len(a) > 1}, "answer_confidence": {}}
            page += 1
    for s in range(rng.choice([3, 6, 11, 14])):
        v = rng.choice(versions + ([None] if rng.random() < 0.1 else []))
        ability = rng.random()
        responses = {}
        for i in items:
            q = numbers[v or versions[0]][i]
            roll = rng.random()
            if roll < 0.05:
                responses[q] = "BLANK"
            elif roll < ability:
                responses[q] = answers[v or versions[0]][i]
            else:
                responses[q] = rng.choice(["A", "B", "C", "D", "E", "AB"])
        sid = rng.choice([f"9{rng.randrange(10**5):05d}", "12_456", ""])
        sheets[page] = {"version": v, "is_key": False, "student_id": sid or None, "answers": {
            q: ("MULTIPLE" if len(a) > 1 and a != "BLANK" else a) for q, a in responses.items()},
            "marks": {q: a for q, a in responses.items() if len(a) > 1 and a != "BLANK"},
            "answer_confidence": {}}
        page += 1

    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "package.csv"
        path.write_text(text)
        package = version_package.load_package(path)
        problems = version_package.write_package_analysis(
            package=package, results_by_page=sheets, out_dir=directory, pdf_path="t.pdf",
            exam_name="T", selected_pages=set(sheets), processed_pages=sorted(sheets),
            skipped_blank=[], skipped_unsupported=[], flag_thresholds=(25, 40, 50), run_id="r",
            scan_student_ids=True, log=lambda _line: None,
        )
        result = None if problems else json.loads((Path(directory) / "analysis_result.json").read_text())
        summary = None if problems else json.loads((Path(directory) / "analysis_summary.json").read_text())
    return {
        "csv": text,
        "sheets": [
            {"page": p, "version": s["version"], "is_key": s["is_key"], "student_id": s["student_id"],
             "responses": {str(q): (s["marks"].get(q) or a) for q, a in s["answers"].items()}}
            for p, s in sheets.items()
        ],
        "problems": problems,
        "scores": None if result is None else {str(s["page"]): s["score"]["correct"] for s in result["students"]},
        "items": None if result is None else {
            i["item"]: {"pct": i["percent_correct"], "by_version": i["pct_correct_by_version"],
                        "pb": i["point_biserial"], "disc": i["upper_lower_discrimination"]}
            for i in result["items"]
        },
        "standards": None if result is None else result["standards"],
        "sections": None if result is None else result["sections"],
        "kr20": None if summary is None else summary["class_statistics"]["kr20"],
        "mismatches": None if summary is None else len(summary["key_mismatches"]),
    }


def main():
    rng = random.Random(2026)
    cases = [make_case(rng, i) for i in range(60)]
    OUT.write_text(json.dumps(cases, indent=1))
    print(f"wrote {OUT.relative_to(ROOT)} ({len(cases)} cases, "
          f"{sum(1 for c in cases if c['problems'])} refused)")


if __name__ == "__main__":
    main()

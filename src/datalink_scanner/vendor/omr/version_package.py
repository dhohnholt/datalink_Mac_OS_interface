"""
version_package.py — Score every version of one test in a single run, from
a "test package" CSV that names each item, where it sits on each version and,
optionally, its answer there.

    Stable item ID,Section,Standard,Version 1,Version 1 answer,Version 2,Version 2 answer
    original-3,Presidency,USG.7B,1,E,14,C

* One row per item. "Stable item ID" ties an item together across versions.
* "Version N" is the question number the item has on version N.
* "Version N answer" is its answer there: a letter, or several letters for a
  multiple-answer item (e.g. AC), which a student must fill exactly. When the
  answer columns are absent, each version's key is read from its scanned key
  sheet instead; when they are present, a scanned key is only compared.
* "Section" and "Standard" are optional and group the results.

Students are scored on their own version's key; item analysis is reported per
item, combined across versions, and results are grouped by standard and
section. Scores need only the question mapping, so they stay right when the
versions also shuffle answer choices; "most common wrong answer" is reported
per version, because a letter means a different choice on each.
"""

import csv
import json
import math
import os
import re
import statistics
import uuid
from datetime import datetime, timezone

from analysis_core import VALID_ANSWERS, is_correct, is_multiple_answer_key
from result_schema import SCHEMA_VERSION, normalized_student_id

MAX_QUESTION = 75

AGENT_PROMPT = """\
Create the files for a multiple-version test that will be scored by the DataLink exam analyzer.

From the test versions I give you, write ONE CSV file named test-package.csv. Use exactly these column
headers, in this order, with one "Version N" and "Version N answer" pair for every version
(Version 1, Version 2, Version 3, Version 4 as needed):

Stable item ID,Section,Standard,Version 1,Version 1 answer,Version 2,Version 2 answer

Rules:
1. One row per test item. The same item appears in one row no matter where it sits on each version.
2. Stable item ID: a short, unique, permanent name for the item (letters, numbers and hyphens, e.g.
   presidency-veto-power). Reuse the same ID if the item appears on a later test.
3. Section: the part of the test the item belongs to (e.g. Presidency, CBA review, Vocabulary).
4. Standard: the standard the item assesses (e.g. USG.7B). Leave blank if none.
5. Version N: the item's question number as printed on version N (1 to 75). Each number is used once
   per version.
6. Version N answer: the correct letter on version N, A to E, after any shuffling of answer choices on
   that version. For an item with more than one correct answer, write every correct letter together
   with no spaces or commas, in alphabetical order (e.g. AC). Students must fill exactly those bubbles.
7. Every item must have a number and an answer for every version.
8. Plain CSV, UTF-8, no blank rows, no notes above or below the table. Quote any field that contains a
   comma.

Example:
Stable item ID,Section,Standard,Version 1,Version 1 answer,Version 2,Version 2 answer
presidency-veto-power,Presidency,USG.7B,1,E,14,C
presidency-cabinet,Presidency,USG.7B,2,E,3,D
cba-judicial-review,CBA review,USG.7C,26,C,25,A

Before you finish, check every row against each version's answer key and confirm that each version
uses each question number only once.
"""


class Package:
    def __init__(self, items, versions, numbers, answers, sections, standards, has_answers):
        self.items = items              # item IDs, in file order
        self.versions = versions        # e.g. ["1", "2"]
        self.numbers = numbers          # {version: {item: question}}
        self.answers = answers          # {version: {item: answer}}; empty without answer columns
        self.sections = sections        # {item: section}
        self.standards = standards      # {item: standard}
        self.has_answers = has_answers

    def item_at(self, version, question):
        return self._by_question[version].get(question)

    def finish(self):
        self._by_question = {
            v: {q: item for item, q in self.numbers[v].items()} for v in self.versions
        }
        return self


def _normalized_answer(text):
    letters = "".join(sorted(set(text.strip().upper().replace(",", "").replace(" ", ""))))
    if not letters or not (letters in VALID_ANSWERS or is_multiple_answer_key(letters)):
        return None
    return letters


def load_package(path):
    """Read and check a test package; raise ValueError naming every problem."""
    with open(path, newline="", encoding="utf-8-sig") as stream:
        reader = csv.reader(stream)
        rows = [row for row in reader if any(cell.strip() for cell in row)]
    if not rows:
        raise ValueError("the test package is empty")
    header = [cell.strip() for cell in rows[0]]
    lower = [cell.lower() for cell in header]

    def column(*names):
        for name in names:
            if name in lower:
                return lower.index(name)
        return None

    id_col = column("stable item id", "item id", "item")
    if id_col is None:
        raise ValueError('the test package needs a "Stable item ID" column')
    section_col = column("section")
    standard_col = column("standard", "teks")
    number_cols, answer_cols = {}, {}
    for index, name in enumerate(lower):
        match = re.fullmatch(r"(?:version|v)\s*([1-4])", name)
        if match:
            number_cols[match.group(1)] = index
        match = re.fullmatch(r"(?:version|v)\s*([1-4])\s*(?:answer|key)", name)
        if match:
            answer_cols[match.group(1)] = index
    versions = sorted(number_cols)
    if not versions:
        raise ValueError('the test package needs a column per version, such as "Version 1"')
    has_answers = bool(answer_cols)
    if has_answers and sorted(answer_cols) != versions:
        raise ValueError(
            "every version needs an answer column: found answers for version(s) "
            f"{', '.join(sorted(answer_cols))} and numbers for {', '.join(versions)}"
        )

    problems = []
    items, sections, standards = [], {}, {}
    numbers = {v: {} for v in versions}
    answers = {v: {} for v in versions} if has_answers else {}
    used = {v: {} for v in versions}
    for line, row in enumerate(rows[1:], start=2):
        cell = lambda i: row[i].strip() if i is not None and i < len(row) else ""  # noqa: E731
        item = cell(id_col)
        if not item:
            problems.append(f"line {line}: no Stable item ID")
            continue
        if item in sections:
            problems.append(f"line {line}: item {item} appears twice")
            continue
        items.append(item)
        sections[item] = cell(section_col)
        standards[item] = cell(standard_col)
        for v in versions:
            text = cell(number_cols[v])
            if not text.isdigit() or not 1 <= int(text) <= MAX_QUESTION:
                problems.append(f"line {line}: Version {v} must be a question number from 1 to {MAX_QUESTION}, not {text!r}")
                continue
            q = int(text)
            if q in used[v]:
                problems.append(f"line {line}: Version {v} question {q} is already item {used[v][q]}")
                continue
            used[v][q] = item
            numbers[v][item] = q
            if has_answers:
                answer = _normalized_answer(cell(answer_cols[v]))
                if answer is None:
                    problems.append(f"line {line}: Version {v} answer must be letters A-E, not {cell(answer_cols[v])!r}")
                else:
                    answers[v][item] = answer
    if not items:
        problems.append("the test package has no items")
    if problems:
        raise ValueError("the test package has problems:\n  " + "\n  ".join(problems))
    return Package(items, versions, numbers, answers, sections, standards, has_answers).finish()


# ------------------------------------------------------------------ scoring

def _stats(values):
    if not values:
        return {"mean": None, "median": None, "standard_deviation": None, "minimum": None, "maximum": None}
    return {
        "mean": round(statistics.mean(values), 2),
        "median": round(statistics.median(values), 2),
        "standard_deviation": round(statistics.stdev(values), 2) if len(values) > 1 else None,
        "minimum": min(values),
        "maximum": max(values),
    }


def _point_biserial(item_scores, totals):
    n = len(item_scores)
    if n < 3 or len(set(item_scores)) < 2:
        return None
    rest = [t - i for t, i in zip(totals, item_scores)]
    if len(set(rest)) < 2:
        return None
    p = sum(item_scores) / n
    right = [r for r, i in zip(rest, item_scores) if i]
    wrong = [r for r, i in zip(rest, item_scores) if not i]
    sd = statistics.stdev(rest)
    return round(((statistics.mean(right) - statistics.mean(wrong)) / sd) * math.sqrt(p * (1 - p)), 3) if sd else None


def write_package_analysis(*, package, results_by_page, out_dir, pdf_path, exam_name, package_path=None,
                           selected_pages, processed_pages, skipped_blank, skipped_unsupported,
                           flag_thresholds, run_id, scan_student_ids, log):
    """Score the whole batch against the package. Returns a list of errors
    that stopped scoring (empty when the reports were written)."""
    key_pages = sorted(p for p, r in results_by_page.items() if r.get("is_key"))
    scanned_keys = {}
    for page in key_pages:
        version = results_by_page[page].get("version")
        if version in package.versions and version not in scanned_keys:
            scanned_keys[version] = page

    # Each version's key, by item.
    keys, mismatches, errors = {}, [], []
    for v in package.versions:
        page = scanned_keys.get(v)
        read = {}
        if page is not None:
            sheet = results_by_page[page]
            for item, q in package.numbers[v].items():
                answer = sheet.get("marks", {}).get(q) or sheet["answers"].get(q, "BLANK")
                read[item] = answer
        if package.has_answers:
            keys[v] = dict(package.answers[v])
            for item, answer in read.items():
                if answer != keys[v][item]:
                    mismatches.append({
                        "version": v, "question": package.numbers[v][item], "item": item,
                        "package": keys[v][item], "key_sheet": answer, "key_page": page,
                    })
        elif page is None:
            errors.append(f"no answer key sheet bubbled with version {v} was found, and the package has no answers")
        else:
            bad = {package.numbers[v][i]: a for i, a in read.items()
                   if not (a in VALID_ANSWERS or is_multiple_answer_key(a))}
            if bad:
                errors.append(f"the version {v} key sheet (page {page}) could not be read on question(s) "
                              + ", ".join(str(q) for q in sorted(bad)))
            keys[v] = read
    if errors:
        return errors

    log(f"Test package: {len(package.items)} items, versions {', '.join(package.versions)}; "
        + ("answers from the package" if package.has_answers else "answers from the scanned key sheets"))
    for v in package.versions:
        if v in scanned_keys:
            log(f"  Version {v} key sheet: page {scanned_keys[v]}")
    for m in mismatches:
        log(f"  KEY CHECK: version {m['version']} question {m['question']} ({m['item']}): "
            f"package says {m['package']}, key sheet (page {m['key_page']}) shows {m['key_sheet']}")

    students, excluded, review_items = {}, [], []
    for page, sheet in sorted(results_by_page.items()):
        if page in key_pages:
            continue
        version = sheet.get("version")
        if version in package.versions:
            students[page] = sheet
        elif version is None and len(package.versions) == 1:
            students[page] = {**sheet, "version": package.versions[0]}
            review_items.append({"page": page, "field": "version", "value": None})
        else:
            excluded.append((page, f"version {version}" if version else "no version bubbled"))
    for page, reason in excluded:
        log(f"Not scored: page {page} ({reason})")
    if not students:
        return ["no student sheets bubbled with a version in the package were found"]

    # correct[page][item] -> 0/1
    correct, given_by = {}, {}
    for page, sheet in students.items():
        v = sheet["version"]
        correct[page], given_by[page] = {}, {}
        for item in package.items:
            q = package.numbers[v][item]
            given = sheet["answers"].get(q, "BLANK")
            marks = sheet.get("marks", {}).get(q)
            correct[page][item] = int(is_correct(given, keys[v][item], marks))
            given_by[page][item] = marks if (given == "MULTIPLE" and marks) else given
            confidence = sheet.get("answer_confidence", {}).get(q, {})
            expected_several = given == "MULTIPLE" and is_multiple_answer_key(keys[v][item])
            if confidence.get("needs_review") and not expected_several:
                review_items.append({"page": page, "field": "answer", "question": q,
                                     "value": given, "confidence": confidence})
        sid = sheet.get("student_id")
        if scan_student_ids and sid and ("_" in sid or "?" in sid):
            review_items.append({"page": page, "field": "student_id", "value": sid})
    for m in mismatches:
        review_items.append({"page": m["key_page"], "field": "key", "question": m["question"],
                             "value": m["key_sheet"], "expected": m["package"], "version": m["version"]})

    total = len(package.items)
    pages = sorted(students)
    totals = [sum(correct[p].values()) for p in pages]
    scores = {}
    for page, points in zip(pages, totals):
        v = students[page]["version"]
        missed = sorted(package.numbers[v][i] for i in package.items if not correct[page][i])
        given = [given_by[page][i] for i in package.items]
        scores[page] = {
            "version": v, "correct": points, "total": total,
            "percentage": round(points / total * 100, 1),
            "blank": given.count("BLANK"),
            "multiple": sum(1 for g in given if g != "BLANK" and len(g) > 1),
            "missed_questions": missed,
        }

    # Item analysis, per item across versions.
    n = len(pages)
    group_n = max(1, round(n * 0.27))
    ranked = sorted(range(n), key=lambda i: totals[i])
    items = []
    for item in package.items:
        scores_i = [correct[p][item] for p in pages]
        n_correct = sum(scores_i)
        pct = round(n_correct / n * 100, 1)
        per_version, wrong = {}, {}
        for v in package.versions:
            on_v = [p for p in pages if students[p]["version"] == v]
            right = sum(correct[p][item] for p in on_v)
            per_version[v] = round(right / len(on_v) * 100, 1) if on_v else None
            counts = {}
            for p in on_v:
                g = given_by[p][item]
                if not correct[p][item] and g != "BLANK":
                    counts[g] = counts.get(g, 0) + 1
            wrong[v] = max(counts, key=counts.get) if counts else None
        discrimination = None
        if n >= 10:
            lower = [scores_i[i] for i in ranked[:group_n]]
            upper = [scores_i[i] for i in ranked[-group_n:]]
            discrimination = round(sum(upper) / group_n - sum(lower) / group_n, 3)
        items.append({
            "item": item,
            "section": package.sections[item],
            "standard": package.standards[item],
            "questions": {v: package.numbers[v][item] for v in package.versions},
            "answers": {v: keys[v][item] for v in package.versions},
            "n_correct": n_correct,
            "pct_correct": pct,
            "difficulty": round(n_correct / n, 3),
            "point_biserial": _point_biserial(scores_i, totals),
            "upper_lower_discrimination": discrimination,
            "pct_correct_by_version": per_version,
            "most_common_wrong_by_version": wrong,
            "flags": {f"missed_{t}": (100 - pct) > t for t in flag_thresholds},
        })

    kr20 = None
    variance = statistics.pvariance(totals) if n > 1 else 0
    if total > 1 and variance > 0:
        pq = sum(i["difficulty"] * (1 - i["difficulty"]) for i in items)
        kr20 = round(total / (total - 1) * (1 - pq / variance), 3)
    stats = {"student_count": n, **_stats(totals), "kr20": kr20}

    def grouped(field):
        """{group: {"items": n, "class_pct": x, "by_page": {page: (right, n)}}}"""
        groups = {}
        for item in package.items:
            name = getattr(package, field)[item] or "(none)"
            g = groups.setdefault(name, {"items": [], "by_page": {}})
            g["items"].append(item)
        for name, g in groups.items():
            for p in pages:
                right = sum(correct[p][i] for i in g["items"])
                g["by_page"][p] = (right, len(g["items"]))
            all_right = sum(r for r, _ in g["by_page"].values())
            g["class_pct"] = round(all_right / (len(g["items"]) * n) * 100, 1)
        return groups

    standards = grouped("standards")
    sections = grouped("sections")

    # ------------------------------------------------------------- reports
    version_cols = [f"V{v} #" for v in package.versions]
    with open(os.path.join(out_dir, "student_scores.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["Page", "Student ID", "Version", "Correct", "Total", "Percentage",
                    "Blank", "Multiple", "Missed Questions"])
        for page in sorted(pages, key=lambda p: -scores[p]["percentage"]):
            s = scores[page]
            w.writerow([page, students[page].get("student_id"), s["version"], s["correct"], total,
                        f'{s["percentage"]}%', s["blank"], s["multiple"],
                        ";".join(str(q) for q in s["missed_questions"])])

    with open(os.path.join(out_dir, "item_analysis.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["Question", "Item ID", "Section", "Standard", *version_cols, "Correct Answer",
                    "N Correct", "% Correct", *[f"V{v} % correct" for v in package.versions],
                    "Difficulty", "Point Biserial", "Upper-Lower Discrimination", "Most Common Wrong",
                    *[f"Flag >{t}% missed" for t in flag_thresholds]])
        first = package.versions[0]
        for it in sorted(items, key=lambda i: i["questions"][first]):
            w.writerow([
                it["questions"][first], it["item"], it["section"], it["standard"],
                *[it["questions"][v] for v in package.versions],
                " · ".join(f"V{v} {it['answers'][v]}" for v in package.versions),
                it["n_correct"], it["pct_correct"],
                *[it["pct_correct_by_version"][v] if it["pct_correct_by_version"][v] is not None else ""
                  for v in package.versions],
                it["difficulty"], it["point_biserial"], it["upper_lower_discrimination"],
                " · ".join(f"V{v} {it['most_common_wrong_by_version'][v]}"
                           for v in package.versions if it["most_common_wrong_by_version"][v]),
                *["YES" if it["flags"][f"missed_{t}"] else "" for t in flag_thresholds],
            ])

    with open(os.path.join(out_dir, "standards.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["Group", "Name", "Items", "Class % correct"])
        for kind, groups in (("Standard", standards), ("Section", sections)):
            for name, g in groups.items():
                w.writerow([kind, name, len(g["items"]), g["class_pct"]])

    with open(os.path.join(out_dir, "student_standards.csv"), "w", newline="") as f:
        w = csv.writer(f)
        names = list(standards)
        w.writerow(["Page", "Student ID", "Version", *names])
        for page in pages:
            w.writerow([page, students[page].get("student_id"), students[page]["version"],
                        *[f"{standards[name]['by_page'][page][0]}/{standards[name]['by_page'][page][1]}"
                          for name in names]])

    with open(os.path.join(out_dir, "review_items.json"), "w") as f:
        json.dump(review_items, f, indent=2)
    summary = {
        "form": "package",
        "class_statistics": stats,
        "question_count": total,
        "versions": package.versions,
        "selected_pages": sorted(selected_pages),
        "processed_pages": processed_pages,
        "skipped_blank": skipped_blank,
        "skipped_unsupported": skipped_unsupported,
        "review_item_count": len(review_items),
        "student_id_scanning": scan_student_ids,
        "key_source": "package" if package.has_answers else "key sheets",
        "key_mismatches": mismatches,
        "not_scored": excluded,
    }
    with open(os.path.join(out_dir, "analysis_summary.json"), "w") as f:
        json.dump(summary, f, indent=2)

    result = {
        "schema_version": SCHEMA_VERSION,
        "run_id": run_id or str(uuid.uuid4()),
        "status": "completed",
        "created_at": datetime.now(timezone.utc).isoformat(),
        "exam": {
            "name": exam_name or os.path.splitext(os.path.basename(pdf_path))[0],
            "source_file": os.path.basename(pdf_path),
            "source_type": "pdf_scan",
            "form": "package",
            "student_id_scanning": scan_student_ids,
            "question_count": total,
            "versions": package.versions,
            "key_source": summary["key_source"],
            "package_file": os.path.abspath(package_path) if package_path else None,
            "key_pages": scanned_keys,
            "items": [
                {"item": it["item"], "section": it["section"], "standard": it["standard"],
                 "questions": it["questions"], "answers": it["answers"]}
                for it in items
            ],
            "selected_pages": sorted(selected_pages),
            "processed_pages": sorted(processed_pages),
            "flag_thresholds": list(flag_thresholds),
        },
        "summary": {
            **stats,
            "mean_percentage": round(stats["mean"] / total * 100, 1) if stats["mean"] is not None else None,
            "median_percentage": round(stats["median"] / total * 100, 1) if stats["median"] is not None else None,
        },
        "students": [
            {
                "page": page,
                "student_id": normalized_student_id(students[page].get("student_id")),
                "student_id_read": students[page].get("student_id"),
                "student_name": None,
                "version": students[page]["version"],
                "score": {k: scores[page][k] for k in
                          ("correct", "total", "percentage", "blank", "multiple", "missed_questions")},
                "standards": {name: {"correct": g["by_page"][page][0], "items": g["by_page"][page][1]}
                              for name, g in standards.items()},
                "answers": [
                    {"item": item, "question": package.numbers[students[page]["version"]][item],
                     "response": given_by[page][item],
                     "correct_answer": keys[students[page]["version"]][item],
                     "correct": bool(correct[page][item])}
                    for item in package.items
                ],
            }
            for page in pages
        ],
        "items": [
            {**{k: it[k] for k in ("item", "section", "standard", "questions", "answers", "n_correct")},
             "percent_correct": it["pct_correct"], "correct_answer": " · ".join(
                 f"V{v} {it['answers'][v]}" for v in package.versions),
             "question": it["questions"][package.versions[0]],
             **{k: it[k] for k in ("difficulty", "point_biserial", "upper_lower_discrimination",
                                   "pct_correct_by_version", "most_common_wrong_by_version")},
             "flags": [name for name, on in it["flags"].items() if on]}
            for it in items
        ],
        "standards": {name: {"items": len(g["items"]), "class_pct": g["class_pct"]} for name, g in standards.items()},
        "sections": {name: {"items": len(g["items"]), "class_pct": g["class_pct"]} for name, g in sections.items()},
        "review_items": review_items,
        "warnings": ([{"code": "key_mismatch", "count": len(mismatches)}] if mismatches else [])
                    + ([{"code": "review_required", "count": len(review_items)}] if review_items else []),
        "corrections": [],
    }
    with open(os.path.join(out_dir, "analysis_result.json"), "w") as f:
        json.dump(result, f, indent=2)

    log(f"\nScored {n} students across versions {', '.join(package.versions)}. "
        f"Class average: {stats['mean'] / total * 100:.1f}%")
    return []

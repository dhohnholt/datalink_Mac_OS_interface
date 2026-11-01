"""
vocab_scoring.py — Scoring, item analysis and reports for the printable
sheets whose key decides which questions count: the 20-question vocabulary
quiz (vocab_sheet_layout) and the 50-question sheet with 15-term matching
(match_sheet_layout). Each function takes the sheet's layout module.

Every question is worth one point and scores 1 or 0. A select-all question
earns its point only when the student filled exactly the choices the key
filled: every correct one, and nothing else.

The key decides which questions count: a row left blank on the key is not
scored, so a quiz with five matching terms needs no question count.

Reports keep the column names and JSON fields of the multiple-choice
analysis so the interface shows them unchanged.
"""

import csv
import json
import math
import os
import statistics
from datetime import datetime, timezone
import uuid

import vocab_sheet_layout as V
from result_schema import SCHEMA_VERSION, normalized_student_id

PART_LABELS = V.PART_LABELS


def resolve_key(key_answers, overrides=None, layout=V):
    """
    Return (key, unresolved): key maps each scored question to its answer
    (a letter, or the sorted letters of a select-all question); unresolved
    maps questions whose key mark could not be read to what was seen.
    """
    overrides = {int(q): str(v).upper().replace(",", "").replace(" ", "")
                 for q, v in (overrides or {}).items()}
    key, unresolved = {}, {}
    for q in range(1, layout.QUESTION_COUNT + 1):
        options = layout.options_for(q)
        kind = layout.question_type(q)
        answer = overrides.get(q, key_answers.get(q, "BLANK"))
        if q in overrides:
            if answer in ("", "-", "BLANK"):
                continue
            letters = "".join(sorted(set(answer)))
            if not letters or any(ch not in options for ch in letters) or (
                kind not in layout.MULTI_TYPES and len(letters) != 1
            ):
                raise ValueError(f"invalid key override for question {q}: {answer!r}")
            key[q] = letters
            continue
        if answer == "BLANK":
            continue
        if answer == "MULTIPLE":
            unresolved[q] = answer
            continue
        key[q] = answer
    return key, unresolved


def question_credit(question, key_answer, given):
    """1 for a right answer, 0 otherwise. Select-all answers are stored as
    sorted letters, so an exact match is string equality there too."""
    return 1.0 if given == key_answer else 0.0


def score_student(answers, key, layout=V):
    points = 0.0
    parts = {name: 0.0 for name in layout.PART_LABELS}
    part_totals = {name: 0 for name in layout.PART_LABELS}
    blank = multiple = 0
    missed = []
    for q, key_answer in key.items():
        given = answers.get(q, "BLANK")
        credit = question_credit(q, key_answer, given)
        kind = layout.question_type(q)
        points += credit
        parts[kind] += credit
        part_totals[kind] += 1
        if given == "BLANK":
            blank += 1
        elif given == "MULTIPLE" or (len(given) > 1 and len(key_answer) == 1):
            # Several marks where one answer was wanted.
            multiple += 1
        if credit < 1.0:
            missed.append(q)
    total = len(key)
    return {
        "correct": round(points, 3),
        "points": round(points, 3),
        "total": total,
        "percentage": round(points / total * 100, 1) if total else 0.0,
        "blank": blank,
        "multiple": multiple,
        "incorrect": len(missed) - blank - multiple,
        "missed_questions": missed,
        "parts": {name: round(value, 3) for name, value in parts.items() if part_totals[name]},
        "part_totals": {name: count for name, count in part_totals.items() if count},
    }


def _pearson(xs, ys):
    if len(xs) < 3 or len(set(xs)) < 2 or len(set(ys)) < 2:
        return None
    mx, my = statistics.mean(xs), statistics.mean(ys)
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    sx = math.sqrt(sum((x - mx) ** 2 for x in xs))
    sy = math.sqrt(sum((y - my) ** 2 for y in ys))
    return round(sxy / (sx * sy), 3) if sx and sy else None


def item_analysis(all_answers, key, flag_thresholds=(25, 40, 50), layout=V):
    n = len(all_answers)
    credits = {
        q: [question_credit(q, key[q], answers.get(q, "BLANK")) for answers in all_answers]
        for q in key
    }
    totals = [sum(credits[q][i] for q in key) for i in range(n)]
    group_n = max(1, round(n * 0.27)) if n else 0
    analysis = {}
    for q, key_answer in key.items():
        options = layout.options_for(q)
        kind = layout.question_type(q)
        item = credits[q]
        counts = {opt: 0 for opt in options}
        counts.update({"BLANK": 0, "MULTIPLE": 0})
        for answers in all_answers:
            given = answers.get(q, "BLANK")
            if given in ("BLANK", "MULTIPLE"):
                counts[given] += 1
            elif kind in layout.MULTI_TYPES:
                # Each letter a student filled is counted, so these show how
                # often each choice was picked rather than adding to 100%.
                for letter in given:
                    counts[letter] += 1
            else:
                counts[given] = counts.get(given, 0) + 1
        wrong = {opt: c for opt, c in counts.items()
                 if opt in options and opt not in key_answer and c > 0}
        mean_credit = statistics.mean(item) if item else 0.0
        pct_correct = round(mean_credit * 100, 1)
        rest = [total - credit for total, credit in zip(totals, item)]
        discrimination = None
        if n >= 10:
            ranked = sorted(zip(totals, item), key=lambda pair: pair[0])
            lower, upper = ranked[:group_n], ranked[-group_n:]
            discrimination = round(
                sum(c for _, c in upper) / group_n - sum(c for _, c in lower) / group_n, 3
            )
        missed_pct = 100 - pct_correct
        analysis[q] = {
            "type": kind,
            "correct_answer": key_answer,
            "n_correct": sum(1 for c in item if c == 1.0),
            "pct_correct": pct_correct,
            "difficulty": round(mean_credit, 3),
            "point_biserial": _pearson(item, rest),
            "upper_lower_discrimination": discrimination,
            "distribution": {
                opt: {"count": c, "pct": round(c / n * 100, 1) if n else 0.0}
                for opt, c in counts.items()
            },
            "most_common_wrong": max(wrong, key=wrong.get) if wrong else None,
            "flags": {f"missed_{t}": missed_pct > t for t in flag_thresholds},
        }
    return analysis, credits


def class_statistics(scores, credits, total):
    raw = [score["points"] for score in scores.values()]
    result = {
        "student_count": len(raw),
        "mean": round(statistics.mean(raw), 2) if raw else None,
        "median": round(statistics.median(raw), 2) if raw else None,
        "standard_deviation": round(statistics.stdev(raw), 2) if len(raw) > 1 else None,
        "minimum": min(raw) if raw else None,
        "maximum": max(raw) if raw else None,
        # KR-20 assumes right/wrong items; Cronbach's alpha is its
        # generalisation to partial credit, and equals it when there is none
        # (both computed with the same variance convention for items and total).
        "kr20": None,
        "cronbach_alpha": None,
    }
    k = len(credits)
    if k > 1 and len(raw) > 1 and statistics.variance(raw) > 0:
        item_var = sum(statistics.variance(values) for values in credits.values())
        result["cronbach_alpha"] = round(k / (k - 1) * (1 - item_var / statistics.variance(raw)), 3)
    return result


def write_vocab_analysis(*, out_dir, pdf_path, exam_name, key_page, key_version,
                         key_answers, key_overrides, students, selected_pages,
                         processed_pages, skipped_blank, skipped_unsupported,
                         excluded_pages, missing_version, applied_corrections,
                         flag_thresholds, run_id, scan_student_ids, log, layout=V):
    """
    Score a vocabulary-quiz batch and write the same report files as the
    multiple-choice analysis. Returns the unresolved key questions; when there
    are any, only answer_key_review.json is written.
    """
    key, unresolved = resolve_key(key_answers, key_overrides, layout)
    if unresolved or not key:
        with open(os.path.join(out_dir, "answer_key_review.json"), "w") as f:
            json.dump({
                "key_page": key_page,
                "answers": key_answers,
                "validation": {
                    "valid": False,
                    "missing": [] if key else ["the key sheet has no answers"],
                    "invalid": {str(q): v for q, v in unresolved.items()},
                },
            }, f, indent=2)
        return unresolved or {"key": "empty"}

    total = len(key)
    log(f"{'Vocabulary quiz' if layout is V else 'Answer sheet'}: scoring {total} question(s) the key marks: "
        + ", ".join(f"{layout.PART_LABELS[name]} {sum(1 for q in key if layout.question_type(q) == name)}"
                    for name in layout.PART_LABELS))

    scores = {page: score_student(r["answers"], key, layout) for page, r in students.items()}
    analysis, credits = item_analysis([r["answers"] for r in students.values()], key, flag_thresholds, layout)
    stats = class_statistics(scores, credits, total)

    review_items = [{"page": page, "field": "version", "value": None} for page in missing_version]
    for page, result in students.items():
        sid = result.get("student_id")
        if scan_student_ids and sid and ("_" in sid or "?" in sid):
            review_items.append({"page": page, "field": "student_id", "value": sid})
        for q in key:
            confidence = result.get("answer_confidence", {}).get(q, {})
            given = result["answers"].get(q, "BLANK")
            several_unwanted = len(given) > 1 and given != "BLANK" and len(key[q]) == 1
            if confidence.get("needs_review") or several_unwanted:
                review_items.append({
                    "page": page, "field": "answer", "question": q,
                    "value": result["answers"][q], "confidence": confidence,
                })

    part_names = [name for name in layout.PART_LABELS if any(layout.question_type(q) == name for q in key)]
    with open(os.path.join(out_dir, "student_scores.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["Page", "Student ID", "Correct", "Total", "Percentage",
                    *[f"{layout.PART_LABELS[name]} points" for name in part_names],
                    "Blank", "Multiple", "Missed Questions"])
        for page, s in sorted(scores.items(), key=lambda kv: -kv[1]["percentage"]):
            w.writerow([page, students[page].get("student_id"), s["points"], total,
                        f'{s["percentage"]}%',
                        *[f'{s["parts"].get(name, 0)}/{s["part_totals"][name]}' for name in part_names],
                        s["blank"], s["multiple"],
                        ";".join(str(q) for q in s["missed_questions"])])

    with open(os.path.join(out_dir, "item_analysis.csv"), "w", newline="") as f:
        w = csv.writer(f)
        letters = sorted({opt for q in range(1, layout.QUESTION_COUNT + 1) for opt in layout.options_for(q)})
        w.writerow(["Question", "Type", "Correct Answer", "N Correct", "% Correct", "Difficulty",
                    "Point Biserial", "Upper-Lower Discrimination",
                    *[f"{letter} %" for letter in letters], "Blank %", "Multiple %",
                    "Most Common Wrong", *[f"Flag >{t}% missed" for t in flag_thresholds]])
        for q, a in analysis.items():
            d = a["distribution"]
            w.writerow([q, layout.PART_LABELS[a["type"]], a["correct_answer"], a["n_correct"],
                        a["pct_correct"], a["difficulty"], a["point_biserial"],
                        a["upper_lower_discrimination"],
                        *[d[letter]["pct"] if letter in d else "" for letter in letters],
                        d["BLANK"]["pct"], d["MULTIPLE"]["pct"], a["most_common_wrong"] or "",
                        *["YES" if a["flags"][f"missed_{t}"] else "" for t in flag_thresholds]])

    with open(os.path.join(out_dir, "review_items.json"), "w") as f:
        json.dump(review_items, f, indent=2)
    with open(os.path.join(out_dir, "analysis_summary.json"), "w") as f:
        json.dump({
            "form": layout.FORM_NAME,
            "class_statistics": stats,
            "selected_pages": sorted(selected_pages),
            "processed_pages": processed_pages,
            "skipped_blank": skipped_blank,
            "skipped_unsupported": skipped_unsupported,
            "applied_corrections": applied_corrections,
            "review_item_count": len(review_items),
            "student_id_scanning": scan_student_ids,
            "question_count": total,
            "scored_questions": sorted(key),
            "version": key_version,
            "not_scored": excluded_pages,
        }, f, indent=2)

    student_rows = []
    for page in sorted(students):
        extraction, score = students[page], scores[page]
        student_rows.append({
            "page": page,
            "student_id": normalized_student_id(extraction.get("student_id")),
            "student_id_read": extraction.get("student_id"),
            "student_name": None,
            "version": extraction.get("version"),
            "student_id_manually_corrected": any(
                c["page"] == page and c["field"] == "student_id" for c in applied_corrections
            ),
            "score": {
                "correct": score["points"], "points": score["points"],
                "incorrect": score["incorrect"], "blank": score["blank"],
                "multiple": score["multiple"], "total": total,
                "percentage": score["percentage"], "parts": score["parts"],
                "missed_questions": score["missed_questions"],
            },
            "answers": [
                {
                    "question": q,
                    "type": layout.question_type(q),
                    "response": extraction["answers"].get(q, "BLANK"),
                    "correct_answer": key[q],
                    "credit": round(question_credit(q, key[q], extraction["answers"].get(q, "BLANK")), 3),
                    "correct": question_credit(q, key[q], extraction["answers"].get(q, "BLANK")) == 1.0,
                    "confidence": extraction.get("answer_confidence", {}).get(q, {}),
                    "manually_corrected": False,
                }
                for q in key
            ],
            "calibration": extraction.get("calibration", {}),
        })

    item_rows = [
        {
            "question": q, "type": a["type"], "correct_answer": a["correct_answer"],
            "n_correct": a["n_correct"], "percent_correct": a["pct_correct"],
            "difficulty": a["difficulty"], "point_biserial": a["point_biserial"],
            "upper_lower_discrimination": a["upper_lower_discrimination"],
            "distribution": a["distribution"], "most_common_wrong": a["most_common_wrong"],
            "flags": [name for name, on in a["flags"].items() if on],
        }
        for q, a in analysis.items()
    ]
    warnings = []
    if skipped_blank:
        warnings.append({"code": "blank_pages_skipped", "pages": skipped_blank})
    if skipped_unsupported:
        warnings.append({"code": "unsupported_pages_skipped",
                         "pages": [page for page, _ in skipped_unsupported]})
    if review_items:
        warnings.append({"code": "review_required", "count": len(review_items)})

    result = {
        "schema_version": SCHEMA_VERSION,
        "run_id": run_id or str(uuid.uuid4()),
        "status": "completed",
        "created_at": datetime.now(timezone.utc).isoformat(),
        "exam": {
            "name": exam_name or os.path.splitext(os.path.basename(pdf_path))[0],
            "source_file": os.path.basename(pdf_path),
            "source_type": "pdf_scan",
            "form": layout.FORM_NAME,
            "student_id_scanning": scan_student_ids,
            "question_count": total,
            "key_page": key_page,
            "version": key_version,
            "answer_key": [
                {"question": q, "answer": key[q], "type": layout.question_type(q)} for q in key
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
        "students": student_rows,
        "items": item_rows,
        "review_items": review_items,
        "warnings": warnings,
        "corrections": applied_corrections,
    }
    with open(os.path.join(out_dir, "analysis_result.json"), "w") as f:
        json.dump(result, f, indent=2)

    if scores:
        log(f"\nClass average: {stats['mean'] / total * 100:.1f}%  "
            f"(min {stats['minimum'] / total * 100:.1f}%, max {stats['maximum'] / total * 100:.1f}%)")
    return {}

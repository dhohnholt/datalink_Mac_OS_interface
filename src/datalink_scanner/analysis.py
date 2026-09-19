"""Item analysis over a saved session, in the website's JSON contract.

The scoring itself is not implemented here. `vendor/analysis_core.py` and
`vendor/result_schema.py` are verbatim copies from the omr_final project, and
this module only does what `omr_final/analyze_datalink_csv.py` does for a CSV:
turn scans into the structures those functions expect, then call them.

Keeping the maths in one place is the point. A sheet read by the scanner and a
sheet read by the document-scanner pipeline produce the same report, and the
site that consumes it sees a single schema.
"""

from __future__ import annotations

import hashlib
import json

from .vendor.analysis_core import (
    class_statistics,
    item_analysis,
    score_student,
    validate_answer_key,
)
from .vendor.result_schema import build_analysis_result


DEFAULT_FLAG_THRESHOLDS = (25, 40, 50)

# A mark this faint is scored as an answer but is worth a second look.
#
# The reader treats anything below 0.05 as nothing at all, and separately flags
# two marks of similar weight. What falls between is a mark barely darker than
# the paper, scored with full confidence and never questioned — which is how a
# stray pencil line or a half-erased answer becomes a grade. Across 17 real
# batches (12,263 answered bubbles) a properly filled bubble sits at 0.29.
FAINT_MARK_THRESHOLD = 0.10

# But faintness alone is the wrong test. On a real batch, sixteen of eighteen
# faint marks were on one sheet, every one between 0.056 and 0.098: a student
# pressing lightly, not sixteen stray marks. Listing them all would bury the
# two that mattered.
#
# So a mark is only suspicious when it is faint *for that sheet* — much lighter
# than the same student's other answers, which is what a stray mark or a
# half-erased answer looks like. A sheet that is faint all the way through gets
# one note about the sheet instead.
FAINT_RELATIVE_SHARE = 0.6
FAINT_SHEET_SHARE = 0.25

# The export CSV and the stored scans both use "" for an unanswered bubble and
# a run of letters (or "*") where an erasure left more than one mark. Kept
# identical to normalize_response() in omr_final/analyze_datalink_csv.py.
VALID_ANSWERS = "ABCDE"


class AnalysisError(ValueError):
    """Raised when a session cannot be scored, with a reason for the user."""


def review_key(item: dict) -> str:
    """One stable name for a review item, so a decision about it can be kept.

    Page, what is wrong, and which question — the reason as well, because the
    same answer can be questioned for two different things and settling one
    is not settling the other.
    """
    return ":".join(
        str(part) for part in (
            item.get("page"),
            item.get("field"),
            item.get("question") or 0,
            item.get("reason") or "",
        )
    )


def normalize_response(value: object) -> str:
    text = str(value or "").strip().upper()
    if not text:
        return "BLANK"
    if len(text) == 1 and text in VALID_ANSWERS:
        return text
    if text == "*" or all(letter in VALID_ANSWERS for letter in text):
        return "MULTIPLE"
    raise AnalysisError(f"Unsupported response value {text!r}")


def _answers(scan: dict, question_count: int) -> dict[int, str]:
    responses = list(scan.get("responses") or [])
    return {
        number: normalize_response(
            responses[number - 1] if number <= len(responses) else ""
        )
        for number in range(1, question_count + 1)
    }


def scan_fingerprint(session: dict, scans: list[dict]) -> str:
    """Identify the inputs a score was computed from.

    A retry of one upload must keep its run_id; a re-score after a corrected
    student ID or answer key is a new audit record and must not. Hashing what
    actually went into the score tells the two apart.
    """
    material = json.dumps(
        {
            "questions": session.get("question_count"),
            "scans": [
                [
                    scan.get("number"),
                    scan.get("role"),
                    scan.get("student_id"),
                    scan.get("student_name"),
                    list(scan.get("responses") or []),
                ]
                for scan in sorted(scans, key=lambda item: item.get("number") or 0)
            ],
        },
        sort_keys=True,
    )
    return hashlib.sha256(material.encode()).hexdigest()


def build_session_analysis(
    session: dict,
    scans: list[dict],
    exam_name: str | None = None,
    flag_thresholds: tuple[int, ...] = DEFAULT_FLAG_THRESHOLDS,
    run_id: str | None = None,
    dismissed: set[str] | frozenset[str] = frozenset(),
) -> dict:
    """Score one session and return the upload payload.

    `dismissed` names review items the teacher has already settled. They are
    left out of the report entirely, so the count on screen and the warnings
    sent to the website agree with what was actually decided.
    """
    question_count = int(session.get("question_count") or 0)
    if question_count < 1:
        raise AnalysisError("This session has no question count recorded")

    keys = [scan for scan in scans if scan.get("role") == "key"]
    students = [scan for scan in scans if scan.get("role") != "key"]
    if len(keys) != 1:
        raise AnalysisError(
            "Scoring needs exactly one answer key in the session; "
            f"this one has {len(keys)}"
        )
    if not students:
        raise AnalysisError("This session has no student sheets to score")

    answer_key = _answers(keys[0], question_count)
    validation = validate_answer_key(answer_key, question_count)
    if not validation["valid"]:
        unresolved = sorted({*validation["missing"], *validation["invalid"]})
        raise AnalysisError(
            "The answer key still has blank or multiple marks on question(s) "
            + ", ".join(str(number) for number in unresolved)
        )

    # Keyed by scan number, the way the CSV importer keys by its Scan column.
    parsed: dict[int, dict] = {}
    for fallback, scan in enumerate(students, 2):
        number = int(scan.get("number") or fallback)
        while number in parsed:
            number += 1
        parsed[number] = {
            "student_id": (scan.get("student_id") or "").strip() or None,
            "student_name": (scan.get("student_name") or "").strip() or None,
            "answers": _answers(scan, question_count),
            # Keyed by question number the way the reader reports it; the
            # database keys JSON objects by string.
            "answer_confidence": {
                int(question): value
                for question, value in (scan.get("confidence") or {}).items()
            },
            "calibration": {},
        }

    scores = {
        number: {
            "student_id": row["student_id"],
            **score_student(row["answers"], answer_key, question_count),
        }
        for number, row in parsed.items()
    }
    analysis = item_analysis(
        [row["answers"] for row in parsed.values()],
        answer_key,
        question_count=question_count,
        flag_thresholds=flag_thresholds,
    )
    stats = class_statistics(scores, analysis, question_count)

    review_items = []
    for number, row in parsed.items():
        if not row["student_id"]:
            review_items.append({"page": number, "field": "student_id", "value": None})
        for question, response in row["answers"].items():
            if response == "MULTIPLE":
                review_items.append(
                    {
                        "page": number,
                        "field": "answer",
                        "question": question,
                        "value": response,
                        "reason": "multiple",
                    }
                )
        review_items.extend(faint_marks(number, row))

    if dismissed:
        review_items = [
            item for item in review_items if review_key(item) not in dismissed
        ]

    key_number = int(keys[0].get("number") or 1)
    source_name = session.get("log_path") or f"{session.get('name') or 'session'}.jsonl"
    return build_analysis_result(
        pdf_path=str(source_name),
        exam_name=exam_name or session.get("name") or None,
        key_page=key_number,
        selected_pages={key_number, *parsed},
        processed_pages=[key_number, *parsed],
        skipped_blank=[],
        skipped_unsupported=[],
        answer_key=answer_key,
        students=parsed,
        scores=scores,
        analysis=analysis,
        stats=stats,
        review_items=review_items,
        applied_corrections=[],
        flag_thresholds=flag_thresholds,
        run_id=run_id,
        scan_student_ids=True,
        question_count=question_count,
        # Scans read off the scanner report the same value the CSV importer
        # emits — the site already accepts it, and they came off a DataLink
        # either way. A batch read from a PDF says so instead.
        source_type=(
            "pdf_scan" if session.get("source") == "paper" else "datalink_csv"
        ),
    )


def faint_marks(number: int, row: dict) -> list[dict]:
    """Marks on one sheet that are much lighter than the rest of that sheet."""
    marks = row.get("answer_confidence") or {}
    strengths = {
        question: (marks.get(question) or {}).get("mark_strength")
        for question, response in row["answers"].items()
        if response not in ("BLANK", "MULTIPLE")
    }
    strengths = {q: s for q, s in strengths.items() if s is not None}
    if not strengths:
        return []

    ordered = sorted(strengths.values())
    middle = len(ordered) // 2
    typical = (
        ordered[middle]
        if len(ordered) % 2
        else (ordered[middle - 1] + ordered[middle]) / 2
    )

    faint = [q for q, s in strengths.items() if s < FAINT_MARK_THRESHOLD]
    if len(faint) >= max(1, len(strengths) * FAINT_SHEET_SHARE):
        # The whole sheet reads faint. One note about the sheet is useful; one
        # per question is a wall of noise about a student's pencil.
        return [
            {
                "page": number,
                "field": "sheet",
                "reason": "faint_sheet",
                "value": len(faint),
                "mark_strength": round(typical, 4),
            }
        ]

    return [
        {
            "page": number,
            "field": "answer",
            "question": question,
            "value": row["answers"][question],
            "reason": "faint",
            "mark_strength": strengths[question],
        }
        for question in sorted(faint)
        if strengths[question] < typical * FAINT_RELATIVE_SHARE
    ]


def analysis_filename(session: dict) -> str:
    from .server import safe_export_filename

    name = safe_export_filename(session.get("name") or "")
    return name[: -len(".csv")] + ".json" if name.endswith(".csv") else name + ".json"

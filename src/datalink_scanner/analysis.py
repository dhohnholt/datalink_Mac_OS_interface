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

from .vendor.analysis_core import (
    class_statistics,
    item_analysis,
    score_student,
    validate_answer_key,
)
from .vendor.result_schema import build_analysis_result


DEFAULT_FLAG_THRESHOLDS = (25, 40, 50)

# The export CSV and the stored scans both use "" for an unanswered bubble and
# a run of letters (or "*") where an erasure left more than one mark. Kept
# identical to normalize_response() in omr_final/analyze_datalink_csv.py.
VALID_ANSWERS = "ABCDE"


class AnalysisError(ValueError):
    """Raised when a session cannot be scored, with a reason for the user."""


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


def build_session_analysis(
    session: dict,
    scans: list[dict],
    exam_name: str | None = None,
    flag_thresholds: tuple[int, ...] = DEFAULT_FLAG_THRESHOLDS,
) -> dict:
    """Score one session and return the upload payload."""
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
            "answer_confidence": {},
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
                    }
                )

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
        scan_student_ids=True,
        question_count=question_count,
        # Deliberately the same value the CSV importer emits: the site already
        # accepts it, and the scans came off a DataLink either way.
        source_type="datalink_csv",
    )


def analysis_filename(session: dict) -> str:
    from .server import safe_export_filename

    name = safe_export_filename(session.get("name") or "")
    return name[: -len(".csv")] + ".json" if name.endswith(".csv") else name + ".json"

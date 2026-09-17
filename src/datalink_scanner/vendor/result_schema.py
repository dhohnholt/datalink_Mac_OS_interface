"""Build the versioned JSON contract consumed by website integrations."""

from datetime import datetime, timezone
import os
import uuid

SCHEMA_VERSION = "1.0"


def normalized_student_id(value):
    if not value or "_" in value or "?" in value:
        return None
    return value


def build_analysis_result(
    *, pdf_path, key_page, selected_pages, processed_pages, skipped_blank,
    skipped_unsupported, answer_key, students, scores, analysis, stats,
    review_items, applied_corrections, flag_thresholds, run_id=None,
    exam_name=None, scan_student_ids=True, question_count=50,
    source_type="pdf_scan",
):
    corrected_fields = {
        (entry["page"], entry["field"]) for entry in applied_corrections
    }
    student_rows = []
    for page in sorted(students):
        extraction = students[page]
        score = scores[page]
        answers = []
        for question in range(1, question_count + 1):
            response = extraction["answers"].get(question, "BLANK")
            confidence = extraction.get("answer_confidence", {}).get(question, {})
            answers.append({
                "question": question,
                "response": response,
                "correct_answer": answer_key[question],
                "correct": response == answer_key[question],
                "confidence": confidence,
                "manually_corrected": (page, f"answer_{question}") in corrected_fields,
            })
        student_rows.append({
            "page": page,
            "student_id": normalized_student_id(extraction.get("student_id")),
            "student_id_read": extraction.get("student_id"),
            "student_name": extraction.get("student_name"),
            "student_id_manually_corrected": (page, "student_id") in corrected_fields,
            "score": {
                "correct": score["correct"], "incorrect": score["incorrect"],
                "blank": score["blank"], "multiple": score["multiple"],
                "total": question_count, "percentage": score["percentage"],
                "missed_questions": score["missed_questions"],
            },
            "answers": answers,
            "calibration": extraction.get("calibration", {}),
        })

    item_rows = []
    for question in range(1, question_count + 1):
        item = analysis[question]
        item_rows.append({
            "question": question,
            "correct_answer": item["correct_answer"],
            "n_correct": item["n_correct"],
            "percent_correct": item["pct_correct"],
            "difficulty": item["difficulty"],
            "point_biserial": item["point_biserial"],
            "upper_lower_discrimination": item["upper_lower_discrimination"],
            "distribution": item["distribution"],
            "most_common_wrong": item["most_common_wrong"],
            "flags": [name for name, enabled in item["flags"].items() if enabled],
        })

    warnings = []
    if skipped_blank:
        warnings.append({"code": "blank_pages_skipped", "pages": skipped_blank})
    if skipped_unsupported:
        warnings.append({
            "code": "unsupported_pages_skipped",
            "pages": [page for page, _confidence in skipped_unsupported],
        })
    if review_items:
        warnings.append({"code": "review_required", "count": len(review_items)})

    return {
        "schema_version": SCHEMA_VERSION,
        "run_id": run_id or str(uuid.uuid4()),
        "status": "completed",
        "created_at": datetime.now(timezone.utc).isoformat(),
        "exam": {
            "name": exam_name or os.path.splitext(os.path.basename(pdf_path))[0],
            "source_file": os.path.basename(pdf_path),
            "source_type": source_type,
            "student_id_scanning": scan_student_ids,
            "question_count": question_count,
            "key_page": key_page,
            "answer_key": [
                {"question": q, "answer": answer_key[q]}
                for q in range(1, question_count + 1)
            ],
            "selected_pages": sorted(selected_pages),
            "processed_pages": sorted(processed_pages),
            "flag_thresholds": list(flag_thresholds),
        },
        "summary": {
            **stats,
            "mean_percentage": round(stats["mean"] / question_count * 100, 1) if stats["mean"] is not None else None,
            "median_percentage": round(stats["median"] / question_count * 100, 1) if stats["median"] is not None else None,
        },
        "students": student_rows,
        "items": item_rows,
        "review_items": review_items,
        "warnings": warnings,
        "corrections": applied_corrections,
    }

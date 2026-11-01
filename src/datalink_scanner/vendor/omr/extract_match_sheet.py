#!/usr/bin/env python3
"""
extract_match_sheet.py — Read the printable sheet with 50 multiple-choice
questions and a 15-term matching section (make_match_sheet.py).

extract_custom_sheet finds and straightens the page; this module reads the
answer area:

  1-50   A-E, decided as on the 75-question sheet (darkest bubble against
         its row, with each option's printed-letter level removed). Several
         marks are kept as their letters, e.g. "AC": against a key bubbled
         the same way that is a right answer.
  51-65  A-O matching, one letter each; several marks read as MULTIPLE.
"""

import match_sheet_layout as M
from extract_custom_sheet import read_header, sample_ink_ratio
from extract_template_a import answer_confidence, decide_answer, marked_options


def extract_canonical(canon, angle=0, confidence=1.0, scan_student_id=True):
    raw_darkness = {
        q: {opt: sample_ink_ratio(canon, x, y) for opt, (x, y) in M.answer_bubbles(q).items()}
        for q in range(1, M.QUESTION_COUNT + 1)
    }
    choice_rows = [raw_darkness[q] for q in range(1, M.CHOICE_LAST + 1)]
    option_baselines = {opt: min(row[opt] for row in choice_rows) for opt in M.CHOICE_OPTIONS}

    answers, confidences, types = {}, {}, {}
    for q, ratios in raw_darkness.items():
        kind = M.question_type(q)
        types[q] = kind
        if kind == M.CHOICE:
            answer, _ = decide_answer(ratios, option_baselines=option_baselines)
            confidence_row = answer_confidence(ratios, option_baselines)
            if answer == "MULTIPLE":
                answer = marked_options(ratios, option_baselines)
                # Several marks may be the right answer; whether they are
                # depends on the key, so the scorer decides what to review.
                confidence_row = {**confidence_row, "needs_review": False, "several_marks": True}
        else:
            answer, _ = decide_answer(ratios)
            confidence_row = answer_confidence(ratios, None)
        answers[q] = answer
        confidences[q] = confidence_row

    return {
        "form": M.FORM_NAME,
        **read_header(canon, scan_student_id),
        "answers": answers,
        "question_types": types,
        "raw_darkness": raw_darkness,
        "option_ink_baselines": option_baselines,
        "answer_confidence": confidences,
        "calibration": {
            "form": M.FORM_NAME,
            "orientation_angle": angle,
            "form_code_confidence": confidence,
        },
    }

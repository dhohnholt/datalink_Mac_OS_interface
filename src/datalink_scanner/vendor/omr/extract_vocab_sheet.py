#!/usr/bin/env python3
"""
extract_vocab_sheet.py — Read the printable 20-question vocabulary quiz
sheet produced by make_vocab_sheet.py.

extract_custom_sheet finds the page and straightens it (the two printable
forms share their corner squares and header); this module reads the three
answer parts:

  Parts 1-2 (matching A-J, context A-D): one choice per row, decided the
  same way as every other form -- the darkest bubble against the rest of
  its row.

  Part 3 (select all that apply, A-E): several bubbles may be filled, so a
  row cannot be judged against itself. Each bubble is measured against the
  page's empty-bubble level instead, the way the single ANSWER KEY bubble
  is, and anything in between filled and empty is flagged for review.
"""

import statistics

import vocab_sheet_layout as V
from extract_custom_sheet import read_header, sample_ink_ratio
from extract_template_a import answer_confidence, decide_answer

# Part 3: fill fraction above the page's empty-bubble level that counts as
# a mark, and the band either side of it that is sent to review.
MARK_THRESH = 0.35
REVIEW_LOW, REVIEW_HIGH = 0.12, 0.60


def read_selections(ratios, paper_level):
    """Part 3 row -> (letters marked, needs_review, strengths)."""
    adjusted = {opt: max(0.0, value - paper_level) for opt, value in ratios.items()}
    marked = "".join(opt for opt in sorted(adjusted) if adjusted[opt] >= MARK_THRESH)
    unclear = any(REVIEW_LOW <= value < REVIEW_HIGH for value in adjusted.values())
    return marked, unclear, adjusted


def extract_canonical(canon, angle=0, confidence=1.0, scan_student_id=True):
    raw_darkness = {
        q: {opt: sample_ink_ratio(canon, x, y) for opt, (x, y) in V.answer_bubbles(q).items()}
        for q in range(1, V.QUESTION_COUNT + 1)
    }
    # Most bubbles on any sheet are empty, so the median reading is the
    # page's empty-bubble level: paper, printed letter, and scanner tone.
    paper_level = statistics.median(v for row in raw_darkness.values() for v in row.values())

    answers, confidences, types = {}, {}, {}
    for q, ratios in raw_darkness.items():
        kind = V.question_type(q)
        types[q] = kind
        if kind == V.MULTIPLE_ANSWER:
            marked, unclear, adjusted = read_selections(ratios, paper_level)
            answers[q] = marked or "BLANK"
            strengths = sorted(adjusted.values(), reverse=True)
            confidences[q] = {
                "mark_strength": round(strengths[0], 4),
                "margin": round(min(abs(v - MARK_THRESH) for v in strengths), 4),
                "needs_review": unclear,
            }
        else:
            answers[q], _ = decide_answer(ratios)
            confidences[q] = answer_confidence(ratios, None)

    return {
        "form": V.FORM_NAME,
        **read_header(canon, scan_student_id),
        "answers": answers,
        "question_types": types,
        "raw_darkness": raw_darkness,
        "paper_level": round(paper_level, 4),
        "answer_confidence": confidences,
        "calibration": {
            "form": V.FORM_NAME,
            "orientation_angle": angle,
            "form_code_confidence": confidence,
        },
    }

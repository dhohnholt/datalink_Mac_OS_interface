#!/usr/bin/env python3
"""
extract_template_a.py — Full OMR pipeline for the primary (Template A)
Apperson DataLink 1200 answer sheet: 50 questions x 5 options (A-E),
plus a 6-digit Student ID grid.

For each page:
  1. Sample darkness at every calibrated bubble position.
  2. Decide per question: which option is marked, or BLANK, or MULTIPLE.
  3. Decode the 6-digit student ID the same way.
  4. Save a per-page JSON record with raw darkness values retained,
     so parsing errors can be investigated later without re-scanning.
"""

import cv2
import numpy as np
import json
import glob
import os
from calibrate_page import calibrate_page, fix_orientation, REF_ROW0_Y, REF_ROW_SPACING

# --- Calibrated grid (400dpi scan, portrait 2384x4384 reference page) ---
ANSWER_ROW0_Y = 1150.0
ANSWER_ROW_SPACING = 109.3
LEFT_COLS = [279.2, 398.4, 517.6, 636.8, 756.0]      # A-E, questions 1-25
RIGHT_COLS = [1126.0, 1240.4, 1354.8, 1469.2, 1583.6]  # A-E, questions 26-50
OPTIONS = "ABCDE"

ID_COLS = [294.2, 414.8, 535.1, 656.1, 776.0, 895.8]   # 6 digit columns
ID_ROW0_Y = 465.8
ID_ROW_SPACING = 63.13

BUBBLE_SAMPLE_RADIUS = 30   # px, at 400dpi
DARK_PIXEL_THRESH = 170     # grayscale value below which a pixel counts as "ink"

# Decision thresholds operate on BASELINE-ADJUSTED ink ratios (each option's
# ratio minus the row's minimum ratio), which cancels out background shading.
ADJ_BLANK_THRESH = 0.05     # below this (adjusted), nothing is considered marked
ADJ_MULTI_RATIO = 0.85      # second-place adjusted >= this fraction of top -> MULTIPLE


def bubble_grid_for_question(q, row0_y=ANSWER_ROW0_Y, row_spacing=ANSWER_ROW_SPACING):
    """Return {option: (x, y)} for question number q (1-50)."""
    if q <= 25:
        row_i = q - 1
        cols = LEFT_COLS
    else:
        row_i = q - 26
        cols = RIGHT_COLS
    y = row0_y + row_i * row_spacing
    return {opt: (cols[j], y) for j, opt in enumerate(OPTIONS)}


def sample_ink_ratio(gray_img, x, y, radius=BUBBLE_SAMPLE_RADIUS, dark_thresh=DARK_PIXEL_THRESH):
    """Fraction of pixels darker than dark_thresh in a square ROI around (x,y).
    Robust to scan brightness/background shading unlike raw mean darkness."""
    h, w = gray_img.shape
    x0, x1 = max(0, int(x - radius)), min(w, int(x + radius))
    y0, y1 = max(0, int(y - radius)), min(h, int(y + radius))
    roi = gray_img[y0:y1, x0:x1]
    if roi.size == 0:
        return 0.0
    return float(np.mean(roi < dark_thresh))


# Backwards-compatible alias used elsewhere in this file
def sample_darkness(gray_img, x, y, radius=BUBBLE_SAMPLE_RADIUS):
    return sample_ink_ratio(gray_img, x, y, radius)


def _adjusted_option_ratios(ratio_by_option, option_baselines=None):
    """Remove option-specific print ink, then shared row shading."""
    normalized = {
        option: value - (option_baselines or {}).get(option, 0.0)
        for option, value in ratio_by_option.items()
    }
    row_baseline = min(normalized.values())
    return {
        option: max(0.0, value - row_baseline)
        for option, value in normalized.items()
    }


def decide_answer(
    ratio_by_option, blank_thresh=ADJ_BLANK_THRESH,
    multi_ratio=ADJ_MULTI_RATIO, option_baselines=None,
):
    """
    Given {option: ink_ratio}, decide the marked option using baseline-
    adjusted ratios (subtracting the row's minimum cancels out shading).
    """
    adjusted = _adjusted_option_ratios(ratio_by_option, option_baselines)
    sorted_opts = sorted(adjusted.items(), key=lambda kv: -kv[1])
    top_opt, top_val = sorted_opts[0]
    second_opt, second_val = sorted_opts[1]

    if top_val < blank_thresh:
        # Option normalization can occasionally subtract most of a very faint
        # mark when the entire row is darker than the rest of the page. Keep a
        # mark that the legacy within-row comparison identifies unambiguously;
        # never use this fallback to override a genuine multiple-mark result.
        if option_baselines is not None:
            legacy, _ = decide_answer(
                ratio_by_option, blank_thresh, multi_ratio,
                option_baselines=None,
            )
            if legacy in OPTIONS:
                return legacy, ratio_by_option
        return "BLANK", ratio_by_option
    if second_val >= blank_thresh and second_val >= multi_ratio * top_val:
        return "MULTIPLE", ratio_by_option
    return top_opt, ratio_by_option


def answer_confidence(ratio_by_option, option_baselines=None):
    """Return review-oriented strength and separation measures."""
    adjusted_by_option = _adjusted_option_ratios(ratio_by_option, option_baselines)
    adjusted = sorted(adjusted_by_option.values(), reverse=True)
    if adjusted[0] < ADJ_BLANK_THRESH and option_baselines is not None:
        legacy = sorted(
            _adjusted_option_ratios(ratio_by_option).values(), reverse=True
        )
        if legacy[0] >= ADJ_BLANK_THRESH and not (
            legacy[1] >= ADJ_BLANK_THRESH and legacy[1] >= ADJ_MULTI_RATIO * legacy[0]
        ):
            adjusted = legacy
    top, second = adjusted[:2]
    return {
        "mark_strength": round(top, 4),
        "margin": round(top - second, 4),
        "needs_review": top < ADJ_BLANK_THRESH or (top > 0 and second >= ADJ_MULTI_RATIO * top),
    }


def extract_id(gray_img, id_row0_y=ID_ROW0_Y, id_row_spacing=ID_ROW_SPACING):
    digits = []
    confidences = []
    for col_x in ID_COLS:
        ratio_by_digit = {}
        for d in range(10):
            y = id_row0_y + d * id_row_spacing
            ratio_by_digit[str(d)] = sample_ink_ratio(gray_img, col_x, y, radius=25)
        baseline = min(ratio_by_digit.values())
        adjusted = {d: v - baseline for d, v in ratio_by_digit.items()}
        sorted_d = sorted(adjusted.items(), key=lambda kv: -kv[1])
        top_digit, top_val = sorted_d[0]
        second_digit, second_val = sorted_d[1]
        if top_val < ADJ_BLANK_THRESH:
            digits.append("_")  # unmarked column
        elif second_val >= ADJ_MULTI_RATIO * top_val:
            digits.append("?")  # ambiguous / multiple marks
        else:
            digits.append(top_digit)
        confidences.append(ratio_by_digit)
    return "".join(digits), confidences


def extract_gray_page(gray, orient_angle=0, orient_conf=None, scan_student_id=True):
    """Extract an already oriented grayscale page without repeating matching."""

    # Per-page translation correction (feed registration varies sheet to
    # sheet even after orientation is fixed).
    page_row0, page_spacing, calib_confidence = calibrate_page(gray)

    # ID grid scales/shifts proportionally to the same correction.
    id_row0 = ID_ROW0_Y + (page_row0 - REF_ROW0_Y)
    id_spacing = ID_ROW_SPACING * (page_spacing / REF_ROW_SPACING)

    if scan_student_id:
        student_id, id_confidences = extract_id(gray, id_row0, id_spacing)
    else:
        student_id, id_confidences = None, []

    raw_darkness = {}
    for q in range(1, 51):
        positions = bubble_grid_for_question(q, page_row0, page_spacing)
        raw_darkness[q] = {
            opt: sample_darkness(gray, x, y)
            for opt, (x, y) in positions.items()
        }

    # The letters printed inside the bubbles do not contain equal amounts of
    # ink (B is especially dark). Estimate each option's unmarked print level
    # from its lightest reading among the 50 rows on this page. This leaves
    # pencil ink comparable across A-E while the per-row adjustment above
    # continues to cancel local background shading. Using the minimum rather
    # than a percentile preserves faint marks when one option is chosen often.
    option_baselines = {
        option: min(raw_darkness[q][option] for q in range(1, 51))
        for option in OPTIONS
    }

    answers = {}
    answer_confidences = {}
    for q, darkness in raw_darkness.items():
        answer, _ = decide_answer(darkness, option_baselines=option_baselines)
        confidence = answer_confidence(darkness, option_baselines)
        answers[q] = answer
        answer_confidences[q] = confidence

    return {
        "student_id": student_id,
        "id_raw_darkness": id_confidences,
        "answers": answers,
        "raw_darkness": raw_darkness,
        "option_ink_baselines": option_baselines,
        "answer_confidence": answer_confidences,
        "calibration": {
            "row0_y": page_row0,
            "row_spacing": page_spacing,
            "confidence": calib_confidence,
            "orientation_angle": orient_angle,
            "orientation_confidence": orient_conf,
        },
    }


def extract_page(image_path):
    gray = cv2.imread(image_path, cv2.IMREAD_GRAYSCALE)
    if gray is None:
        raise FileNotFoundError(image_path)

    # Sheets can be fed through the scanner in any of 4 orientations even
    # though the printed form is identical. Detect and correct that once.
    gray, orient_angle, orient_conf = fix_orientation(gray)
    return extract_gray_page(gray, orient_angle, orient_conf)


if __name__ == "__main__":
    import sys
    test_image = sys.argv[1] if len(sys.argv) > 1 else "pages/hi_page02-02.png"
    result = extract_page(test_image)
    print("Student ID:", result["student_id"])
    print("Answers:")
    for q in range(1, 51):
        print(f"  Q{q}: {result['answers'][q]}")

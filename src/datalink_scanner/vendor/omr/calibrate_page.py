#!/usr/bin/env python3
"""
calibrate_page.py — Per-page alignment correction.

Different physical sheets feed through the scanner with slightly
different vertical (and sometimes horizontal) registration, even
though the printed form itself is identical. Rather than assume one
global pixel grid works for every page, we template-match the
question-number labels (printed text that students never mark, e.g.
"1", "25") from our reference calibration page against each new page,
at two well-separated rows. This gives us a page-specific row0 and
row-spacing so the whole calibrated grid can be shifted/scaled to fit.
"""

import cv2
import numpy as np
import os

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REF_IMG = cv2.imread(os.path.join(_SCRIPT_DIR, "reference_page.png"), cv2.IMREAD_GRAYSCALE)

# Large, distinctive region (ID grid + header) used to detect orientation
# and coarse (dx, dy) translation, independent of the finer per-row
# calibration below. Sheets can be fed through the scanner in any of the
# 4 orientations even though the printed form is otherwise identical.
_ORIENT_TEMPLATE = REF_IMG[380:1000, 60:900]
_ORIENT_TEMPLATE_X0, _ORIENT_TEMPLATE_Y0 = 60, 380

_ROTATIONS = {
    0: None,
    90: cv2.ROTATE_90_COUNTERCLOCKWISE,
    180: cv2.ROTATE_180,
    270: cv2.ROTATE_90_CLOCKWISE,
}


def fix_orientation(gray_img):
    """
    Try all 4 rotations, matching the ID-grid/header region against each,
    and return the (possibly rotated) image using whichever orientation
    gives the best template match. Also returns the match confidence.
    """
    best_img, best_conf, best_angle = gray_img, -1.0, 0
    for angle, rot_code in _ROTATIONS.items():
        candidate = gray_img if rot_code is None else cv2.rotate(gray_img, rot_code)
        h, w = candidate.shape
        th, tw = _ORIENT_TEMPLATE.shape
        if h < th or w < tw:
            continue
        result = cv2.matchTemplate(candidate, _ORIENT_TEMPLATE, cv2.TM_CCOEFF_NORMED)
        _, max_val, _, _ = cv2.minMaxLoc(result)
        if max_val > best_conf:
            best_img, best_conf, best_angle = candidate, max_val, angle
    return best_img, best_angle, best_conf

# Reference row positions (question-number label crops), from our
# Validated against the official 50-answer key: bubble center for row 1 is
# y=1150 on the reference page. The earlier 1125 value sampled the upper
# edge of each bubble and caused faint marks to be missed on some sheets.
REF_ROW0_Y = 1150.0
REF_ROW_SPACING = 109.3
REF_Q_LOW = 1    # question used as the "low" anchor
REF_Q_HIGH = 25  # question used as the "high" anchor (far away = more precise spacing)

NUM_LABEL_X0, NUM_LABEL_X1 = 190, 235  # x-range of the printed question-number text
LABEL_HALF_HEIGHT = 35


def _label_template(question_num):
    y = REF_ROW0_Y + (question_num - 1) * REF_ROW_SPACING
    y0, y1 = int(y - LABEL_HALF_HEIGHT), int(y + LABEL_HALF_HEIGHT)
    return REF_IMG[y0:y1, NUM_LABEL_X0:NUM_LABEL_X1], y0


_TEMPLATE_LOW, _TEMPLATE_LOW_Y0 = _label_template(REF_Q_LOW)
_TEMPLATE_HIGH, _TEMPLATE_HIGH_Y0 = _label_template(REF_Q_HIGH)


def _match_y(gray_img, template, search_y_center, search_radius=350):
    """Find the best-matching y position for `template` near search_y_center."""
    h, w = gray_img.shape
    y0 = max(0, search_y_center - search_radius)
    y1 = min(h, search_y_center + search_radius)
    search_region = gray_img[y0:y1, NUM_LABEL_X0:NUM_LABEL_X1]
    if search_region.shape[0] < template.shape[0]:
        return None, 0.0
    result = cv2.matchTemplate(search_region, template, cv2.TM_CCOEFF_NORMED)
    _, max_val, _, max_loc = cv2.minMaxLoc(result)
    matched_y0 = y0 + max_loc[1]
    return matched_y0, max_val


def calibrate_page(gray_img):
    """
    Returns (row0_y, row_spacing, confidence) for this specific page.

    The printed form is identical across sheets, so row spacing is fixed
    at the reference value; only the vertical translation (row0_y) varies
    per page due to scanner feed registration. We find that translation
    via the big ID-grid/header template match (fix_orientation), which is
    far more reliable than matching individual thin row-number labels.
    """
    result = cv2.matchTemplate(gray_img, _ORIENT_TEMPLATE, cv2.TM_CCOEFF_NORMED)
    _, max_val, _, max_loc = cv2.minMaxLoc(result)
    dy = max_loc[1] - _ORIENT_TEMPLATE_Y0

    row0_y = REF_ROW0_Y + dy
    return float(row0_y), float(REF_ROW_SPACING), float(max_val)


if __name__ == "__main__":
    import sys
    path = sys.argv[1] if len(sys.argv) > 1 else "pages_full/page-60.png"
    img = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
    row0, spacing, conf = calibrate_page(img)
    print(f"{path}: row0_y={row0:.1f}  spacing={spacing:.2f}  confidence={conf:.3f}")
    print(f"  (reference: row0_y={REF_ROW0_Y}  spacing={REF_ROW_SPACING})")

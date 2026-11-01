#!/usr/bin/env python3
"""
extract_custom_sheet.py — Read the printable 75-question answer sheet
produced by make_answer_sheet.py.

For each page:
  1. Find the four solid corner squares and warp the scan onto the
     printed layout (removes feed shift, skew, and scale differences).
  2. Confirm the bottom form-code strip, trying both 0 and 180 degrees,
     which identifies the form and which way up it was fed.
  3. Sample every bubble position from answer_sheet_layout and decide
     answers, student ID digits, version, and the answer-key marker with
     the same baseline-adjusted logic used for the AccuScan form.
"""

import cv2
import numpy as np

import answer_sheet_layout as L
import match_sheet_layout as M
import vocab_sheet_layout as V
from extract_template_a import answer_confidence, decide_answer, marked_options

CANON_DPI = 200
CANON_W = int(round(L.PAGE_W * CANON_DPI))
CANON_H = int(round(L.PAGE_H * CANON_DPI))

# Pencil and pen both read far darker than this; the light-gray letters
# printed inside each bubble read lighter.
DARK_PIXEL_THRESH = 150
# Absolute fill fraction for the single answer-key bubble, which has no
# neighbours in its row to compare against.
KEY_MARK_THRESH = 0.35


def _to_px(x_in, y_in):
    return x_in * CANON_DPI, y_in * CANON_DPI


def _find_fiducials(gray):
    """Return image-space centres {tl, tr, bl, br} of the corner squares."""
    h, w = gray.shape
    dpi = h / L.PAGE_H
    expected = L.FIDUCIAL_SIZE * dpi
    _, binary = cv2.threshold(gray, 128, 255, cv2.THRESH_BINARY_INV)
    contours, _ = cv2.findContours(binary, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

    candidates = []
    for contour in contours:
        x, y, bw, bh = cv2.boundingRect(contour)
        if not (0.70 * expected <= bw <= 1.40 * expected
                and 0.70 * expected <= bh <= 1.40 * expected):
            continue
        if not 0.75 <= bw / bh <= 1.33:
            continue
        if cv2.contourArea(contour) / float(bw * bh) < 0.80:
            continue
        candidates.append((x + bw / 2.0, y + bh / 2.0))

    corners = {"tl": (0, 0), "tr": (w, 0), "bl": (0, h), "br": (w, h)}
    limit = 1.6 * dpi
    found = {}
    for name, (cx, cy) in corners.items():
        best = min(candidates, key=lambda p: (p[0] - cx) ** 2 + (p[1] - cy) ** 2, default=None)
        if best is None or np.hypot(best[0] - cx, best[1] - cy) > limit:
            return None
        found[name] = best
    if len(set(found.values())) != 4:
        return None
    return found


def _warp(gray, fiducials):
    order = ("tl", "tr", "bl", "br")
    src = np.float32([fiducials[k] for k in order])
    dst = np.float32([_to_px(*L.FIDUCIAL_CENTERS[k]) for k in order])
    matrix = cv2.getPerspectiveTransform(src, dst)
    return cv2.warpPerspective(
        gray, matrix, (CANON_W, CANON_H),
        flags=cv2.INTER_AREA, borderValue=255,
    )


# Every printable form shares the corner squares; the code strip says which
# one a page is. Kept here so the vocabulary reader can import this module.
FORM_CODES = {L.FORM_NAME: L.FORM_CODE, V.FORM_NAME: V.FORM_CODE, M.FORM_NAME: M.FORM_CODE}


def _form_code_score(canon, code=L.FORM_CODE):
    """Fraction of form-code cells that read as printed."""
    half = int(L.FORM_CODE_SIZE * CANON_DPI * 0.35)
    hits = 0
    for bit, (x, y) in zip(code, L.form_code_centers()):
        px, py = (int(round(v)) for v in _to_px(x, y))
        cell = canon[py - half:py + half, px - half:px + half]
        dark = cell.size and float(np.mean(cell)) < 128
        hits += int(bool(dark) == (bit == "1"))
    return hits / len(code)


def locate_sheet(gray):
    """
    Return (canonical_image, angle, confidence, form_name) when the page is
    one of the printable forms, otherwise None. angle is the rotation
    applied to the scan.
    """
    base_angle = 0
    if gray.shape[1] > gray.shape[0]:
        gray = cv2.rotate(gray, cv2.ROTATE_90_CLOCKWISE)
        base_angle = 90
    fiducials = _find_fiducials(gray)
    if fiducials is None:
        return None
    canon = _warp(gray, fiducials)
    flipped = cv2.rotate(canon, cv2.ROTATE_180)
    for form, code in FORM_CODES.items():
        if _form_code_score(canon, code) == 1.0:
            return canon, base_angle, 1.0, form
        if _form_code_score(flipped, code) == 1.0:
            return flipped, (base_angle + 180) % 360, 1.0, form
    return None


def is_custom_sheet(gray):
    return locate_sheet(gray) is not None


_SAMPLE_R = int(round(L.SAMPLE_RADIUS * CANON_DPI))
_yy, _xx = np.mgrid[-_SAMPLE_R:_SAMPLE_R + 1, -_SAMPLE_R:_SAMPLE_R + 1]
_DISK = (_xx ** 2 + _yy ** 2) <= _SAMPLE_R ** 2


def sample_ink_ratio(canon, x_in, y_in):
    """Fraction of dark pixels inside the centre disk of one bubble."""
    px, py = (int(round(v)) for v in _to_px(x_in, y_in))
    roi = canon[py - _SAMPLE_R:py + _SAMPLE_R + 1, px - _SAMPLE_R:px + _SAMPLE_R + 1]
    if roi.shape != _DISK.shape:
        return 0.0
    return float(np.mean(roi[_DISK] < DARK_PIXEL_THRESH))


def _decide_group(ratios):
    """Pick one marked choice among a row of bubbles; '_' blank, '?' multiple."""
    choice, _ = decide_answer(ratios)
    return {"BLANK": "_", "MULTIPLE": "?"}.get(choice, choice)


def read_header(canon, scan_student_id=True):
    """Student ID, version and the ANSWER KEY bubble, which every printable
    form carries in the same place."""
    student_id, id_raw = None, []
    if scan_student_id:
        digits = []
        for col in range(L.ID_DIGITS):
            ratios = {d: sample_ink_ratio(canon, x, y) for d, (x, y) in L.id_bubbles(col).items()}
            id_raw.append(ratios)
            digits.append(_decide_group(ratios))
        student_id = "".join(digits)

    version_ratios = {v: sample_ink_ratio(canon, x, y) for v, (x, y) in L.version_bubbles().items()}
    version = _decide_group(version_ratios)
    key_ratio = sample_ink_ratio(canon, *L.KEY_BUBBLE)
    return {
        "student_id": student_id,
        "id_raw_darkness": id_raw,
        "is_key": key_ratio >= KEY_MARK_THRESH,
        "key_mark_darkness": round(key_ratio, 4),
        "version": version if version in L.VERSIONS else None,
        "version_read": version,
        "version_raw_darkness": version_ratios,
    }


def extract_canonical(canon, angle=0, confidence=1.0, scan_student_id=True):
    raw_darkness = {
        q: {opt: sample_ink_ratio(canon, x, y) for opt, (x, y) in L.answer_bubbles(q).items()}
        for q in range(1, L.QUESTION_COUNT + 1)
    }
    option_baselines = {
        opt: min(raw_darkness[q][opt] for q in raw_darkness) for opt in L.OPTIONS
    }
    answers, answer_confidences, marks = {}, {}, {}
    for q, darkness in raw_darkness.items():
        answers[q], _ = decide_answer(darkness, option_baselines=option_baselines)
        answer_confidences[q] = answer_confidence(darkness, option_baselines)
        if answers[q] == "MULTIPLE":
            marks[q] = marked_options(darkness, option_baselines)

    return {
        "form": L.FORM_NAME,
        **read_header(canon, scan_student_id),
        "answers": answers,
        "marks": marks,
        "raw_darkness": raw_darkness,
        "option_ink_baselines": option_baselines,
        "answer_confidence": answer_confidences,
        "calibration": {
            "form": L.FORM_NAME,
            "orientation_angle": angle,
            "form_code_confidence": confidence,
        },
    }


def extract_page(gray, scan_student_id=True):
    """Return the extraction dict, or None when the page is not a printable form."""
    located = locate_sheet(gray)
    if located is None:
        return None
    canon, angle, confidence, form = located
    if form == V.FORM_NAME:
        import extract_vocab_sheet
        return extract_vocab_sheet.extract_canonical(canon, angle, confidence, scan_student_id)
    if form == M.FORM_NAME:
        import extract_match_sheet
        return extract_match_sheet.extract_canonical(canon, angle, confidence, scan_student_id)
    return extract_canonical(canon, angle, confidence, scan_student_id)


if __name__ == "__main__":
    import sys
    image = cv2.imread(sys.argv[1], cv2.IMREAD_GRAYSCALE)
    result = extract_page(image)
    if result is None:
        print("Not a 75-question custom sheet.")
        sys.exit(1)
    print("Student ID:", result["student_id"], " Version:", result["version_read"],
          " Key sheet:", result["is_key"])
    for q in range(1, L.QUESTION_COUNT + 1):
        print(f"  Q{q}: {result['answers'][q]}")

"""Verbatim copies of the paper-scan pipeline from the omr_final project.

These files are NOT edited here. They are byte-for-byte copies of

    omr_final/analyze_exam.py
    omr_final/calibrate_page.py
    omr_final/extract_template_a.py
    omr_final/page_selection.py
    omr_final/reference_page.png

which read an Apperson "Template A" sheet from a rendered PDF page. The
calibration was measured against that reference image, so it ships too.

Nothing in this package is imported by the app itself: it needs OpenCV and
NumPy, which are optional, so `paper.py` runs `analyze_exam.py` as a
subprocess instead. That also keeps a failure in the image pipeline from
taking the app down with it.

Change them in omr_final and re-copy; do not fix them here.
`tests/test_analysis.py` compares these against the originals when that
project is present on disk, so drift shows up as a failing test.
"""

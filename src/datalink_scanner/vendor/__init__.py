"""Verbatim copies of the scoring modules from the omr_final project.

These files are NOT edited here. They are byte-for-byte copies of

    omr_final/analysis_core.py
    omr_final/result_schema.py

so that the JSON this app uploads is identical to the JSON that project's
`analyze_datalink_csv.py` produces from an exported CSV. The website consuming
it sees one contract, whichever tool produced the scans.

Change them in omr_final and re-copy; do not fix them here.
`tests/test_analysis.py` compares these against the originals when that project
is present on disk, so drift shows up as a failing test.
"""

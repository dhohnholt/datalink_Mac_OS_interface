"""
answer_sheet_layout.py — Single source of truth for the printable
75-question answer sheet.

Both the PDF generator (make_answer_sheet.py) and the reader
(extract_custom_sheet.py) take every position from this module, so the
printed form and the scoring grid cannot drift apart. All measurements
are in inches from the TOP-LEFT corner of a US Letter page.
"""

FORM_NAME = "custom75"
PAGE_W, PAGE_H = 8.5, 11.0

QUESTION_COUNT = 75
OPTIONS = "ABCDE"
ID_DIGITS = 6
VERSIONS = "1234"

# Solid black squares in the four corners. The reader finds these and
# straightens the scan onto the grid below, whatever the feed position.
FIDUCIAL_SIZE = 0.30
FIDUCIAL_CENTERS = {
    "tl": (0.60, 0.60),
    "tr": (7.90, 0.60),
    "bl": (0.60, 10.40),
    "br": (7.90, 10.40),
}

# A row of small squares along the bottom edge identifies this form (and
# which way up it was scanned). "1" is printed solid, "0" is left empty.
FORM_CODE = "11010011"
FORM_CODE_X0 = 2.00
FORM_CODE_PITCH = 0.25
FORM_CODE_Y = 10.40
FORM_CODE_SIZE = 0.14

BUBBLE_RADIUS = 0.085
# Only the middle of each bubble is sampled, so the printed outline never
# counts as a mark.
SAMPLE_RADIUS = 0.055

# --- Header: write-in fields (left) ---------------------------------------
WRITE_IN_X0, WRITE_IN_X1 = 0.60, 4.70
WRITE_IN_FIELDS = (
    ("NAME", 1.30),
    ("COURSE", 1.75),
    ("TEST NAME", 2.20),
)
PERIOD_FIELD_Y = 2.65
PERIOD_FIELD_X1 = 2.40

# Version bubbles sit beside the period field.
VERSION_LABEL_X = 2.65
VERSION_X0 = 3.55
VERSION_PITCH = 0.32
VERSION_Y = 2.60

# Teacher-only answer-key marker.
KEY_BOX = (0.60, 3.00, 2.45, 3.80)   # x0, y0, x1, y1
KEY_BUBBLE = (0.90, 3.40)

INSTRUCTIONS_BOX = (2.60, 3.00, 4.70, 3.80)

# --- Header: student ID grid (right) ---------------------------------------
ID_BOX = (5.05, 0.95, 7.65, 3.85)
ID_X0 = 5.55
ID_PITCH = 0.36
ID_WRITE_Y = 1.30          # centre of the write-in boxes above each column
ID_ROW0_Y = 1.65
ID_ROW_PITCH = 0.215

# --- Answer grid ---------------------------------------------------------
ANSWER_TOP_RULE_Y = 4.05
ANSWER_ROW0_Y = 4.32
ANSWER_ROW_PITCH = 0.235
ROWS_PER_COLUMN = 25
ANSWER_BLOCK_X0 = (0.70, 3.20, 5.70)
ANSWER_NUMBER_DX = 0.40    # right edge of the printed question number
ANSWER_BUBBLE_DX = 0.62    # first bubble (A) centre
ANSWER_BUBBLE_PITCH = 0.32


def fiducial_centers():
    return dict(FIDUCIAL_CENTERS)


def form_code_centers():
    return [
        (FORM_CODE_X0 + i * FORM_CODE_PITCH, FORM_CODE_Y)
        for i in range(len(FORM_CODE))
    ]


def answer_bubbles(question):
    """Return {option: (x, y)} for question 1-75."""
    if not 1 <= question <= QUESTION_COUNT:
        raise ValueError(f"question out of range: {question}")
    block, row = divmod(question - 1, ROWS_PER_COLUMN)
    x0 = ANSWER_BLOCK_X0[block] + ANSWER_BUBBLE_DX
    y = ANSWER_ROW0_Y + row * ANSWER_ROW_PITCH
    return {opt: (x0 + i * ANSWER_BUBBLE_PITCH, y) for i, opt in enumerate(OPTIONS)}


def answer_number_anchor(question):
    block, row = divmod(question - 1, ROWS_PER_COLUMN)
    return (
        ANSWER_BLOCK_X0[block] + ANSWER_NUMBER_DX,
        ANSWER_ROW0_Y + row * ANSWER_ROW_PITCH,
    )


def id_bubbles(column):
    """Return {digit: (x, y)} for ID column 0..ID_DIGITS-1."""
    x = ID_X0 + column * ID_PITCH
    return {str(d): (x, ID_ROW0_Y + d * ID_ROW_PITCH) for d in range(10)}


def version_bubbles():
    return {
        v: (VERSION_X0 + i * VERSION_PITCH, VERSION_Y)
        for i, v in enumerate(VERSIONS)
    }

"""
vocab_sheet_layout.py — Single source of truth for the printable
20-question vocabulary quiz sheet.

The header (corner squares, write-in lines, version, ANSWER KEY bubble,
student ID) is the 75-question sheet's, taken from answer_sheet_layout.
Only the form code and the answer area differ. Measurements are inches
from the TOP-LEFT corner of a US Letter page.

The answer area has three fixed parts. Question numbers never move: a quiz
with five matching items still numbers its context questions from 9.
"""

import answer_sheet_layout as A

FORM_NAME = "vocab20"
# Differs from the 75-question sheet's code, so the two are never confused.
FORM_CODE = "10110011"

MATCHING = "matching"
CONTEXT = "context"
MULTIPLE_ANSWER = "multiple_answer"

# (part, first question, last question, options, columns, title, directions)
PARTS = (
    (MATCHING, 1, 8, "ABCDEFGHIJ", 1,
     "PART 1 — MATCHING",
     "Fill the letter of the definition that matches each term. "
     "Some definitions are not used."),
    (CONTEXT, 9, 16, "ABCD", 2,
     "PART 2 — WORDS IN CONTEXT",
     "Fill the one best answer."),
    (MULTIPLE_ANSWER, 17, 20, "ABCDE", 2,
     "PART 3 — SELECT ALL THAT APPLY  (pencil only)",
     "Fill EVERY correct answer and nothing else. You earn the point only if all are right."),
)

QUESTION_COUNT = 20
PART_LABELS = {MATCHING: "Matching", CONTEXT: "Context", MULTIPLE_ANSWER: "Select all"}
# Parts whose key may hold several letters: the student must fill exactly them.
MULTI_TYPES = frozenset({MULTIPLE_ANSWER})
SAMPLE_RADIUS = A.SAMPLE_RADIUS
BUBBLE_RADIUS = A.BUBBLE_RADIUS

ROW_PITCH = 0.30
BUBBLE_PITCH = 0.32
NUMBER_DX = 0.40          # right edge of the printed question number
BUBBLE_DX = 0.62          # first bubble centre
COLUMN_X0 = (0.70, 4.45)

# Each part: the y of its title bar and of its first row of bubbles.
PART_TITLE_Y = {MATCHING: 4.25, CONTEXT: 7.15, MULTIPLE_ANSWER: 8.85}
PART_ROW0_Y = {MATCHING: 4.72, CONTEXT: 7.62, MULTIPLE_ANSWER: 9.32}


def part_of(question):
    for part in PARTS:
        if part[1] <= question <= part[2]:
            return part
    raise ValueError(f"question out of range: {question}")


def question_type(question):
    return part_of(question)[0]


def options_for(question):
    return part_of(question)[3]


def _row_position(question):
    name, first, last, _options, columns, *_ = part_of(question)
    index = question - first
    rows = -(-(last - first + 1) // columns)
    column, row = divmod(index, rows)
    return COLUMN_X0[column], PART_ROW0_Y[name] + row * ROW_PITCH


def answer_bubbles(question):
    """Return {option: (x, y)} for question 1-20."""
    x0, y = _row_position(question)
    return {
        opt: (x0 + BUBBLE_DX + i * BUBBLE_PITCH, y)
        for i, opt in enumerate(options_for(question))
    }


def number_anchor(question):
    x0, y = _row_position(question)
    return x0 + NUMBER_DX, y


def form_code_centers():
    return A.form_code_centers()

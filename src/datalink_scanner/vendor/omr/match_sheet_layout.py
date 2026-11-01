"""
match_sheet_layout.py — Single source of truth for the printable sheet with
50 multiple-choice questions and a 15-term matching section.

  Questions 1-50   two columns, A-E. A key row with several bubbles filled
                   is a multiple-answer question (all or nothing).
  Questions 51-65  the third column: matching, A-O, for up to 15 terms.

The header is the 75-question sheet's (answer_sheet_layout); only the form
code and the answer area differ. Inches from the TOP-LEFT of US Letter. As on
the vocabulary quiz, the key decides which questions count: rows left blank
on the key are not scored.
"""

import answer_sheet_layout as A

FORM_NAME = "match65"
# Differs from every other printable form's code.
FORM_CODE = "11001101"

CHOICE = "choice"
MATCHING = "matching"

QUESTION_COUNT = 65
CHOICE_LAST = 50
CHOICE_OPTIONS = "ABCDE"
MATCH_OPTIONS = "ABCDEFGHIJKLMNO"

PART_LABELS = {CHOICE: "Multiple choice", MATCHING: "Matching"}
# Parts whose key may hold several letters: the student must fill exactly them.
MULTI_TYPES = frozenset({CHOICE})

SAMPLE_RADIUS = A.SAMPLE_RADIUS
BUBBLE_RADIUS = A.BUBBLE_RADIUS
MATCH_BUBBLE_RADIUS = 0.075

# Multiple choice: two columns of 25, same rows as the 75-question sheet.
CHOICE_ROW0_Y = A.ANSWER_ROW0_Y
CHOICE_ROW_PITCH = A.ANSWER_ROW_PITCH
CHOICE_BLOCK_X0 = (0.60, 2.55)
CHOICE_NUMBER_DX = 0.40
CHOICE_BUBBLE_DX = 0.62
CHOICE_BUBBLE_PITCH = 0.30

# Matching: one column of 15 rows with 15 smaller, closer bubbles.
MATCH_TITLE_Y = 4.30
MATCH_X0 = 4.62
MATCH_NUMBER_DX = 0.34
MATCH_BUBBLE_DX = 0.55
MATCH_BUBBLE_PITCH = 0.19
MATCH_ROW0_Y = 4.80
MATCH_ROW_PITCH = 0.34


def question_type(question):
    if 1 <= question <= CHOICE_LAST:
        return CHOICE
    if CHOICE_LAST < question <= QUESTION_COUNT:
        return MATCHING
    raise ValueError(f"question out of range: {question}")


def options_for(question):
    return CHOICE_OPTIONS if question_type(question) == CHOICE else MATCH_OPTIONS


def _row_position(question):
    if question_type(question) == CHOICE:
        block, row = divmod(question - 1, 25)
        x0 = CHOICE_BLOCK_X0[block]
        return x0, CHOICE_ROW0_Y + row * CHOICE_ROW_PITCH, CHOICE_NUMBER_DX, CHOICE_BUBBLE_DX, CHOICE_BUBBLE_PITCH
    row = question - CHOICE_LAST - 1
    return MATCH_X0, MATCH_ROW0_Y + row * MATCH_ROW_PITCH, MATCH_NUMBER_DX, MATCH_BUBBLE_DX, MATCH_BUBBLE_PITCH


def answer_bubbles(question):
    """Return {option: (x, y)} for question 1-65."""
    x0, y, _ndx, bdx, pitch = _row_position(question)
    return {opt: (x0 + bdx + i * pitch, y) for i, opt in enumerate(options_for(question))}


def number_anchor(question):
    x0, y, ndx, _bdx, _pitch = _row_position(question)
    return x0 + ndx, y


def bubble_radius(question):
    return BUBBLE_RADIUS if question_type(question) == CHOICE else MATCH_BUBBLE_RADIUS

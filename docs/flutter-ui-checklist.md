# UI parity checklist

Built from a full read of `src/datalink_scanner/webui/app.js` (2,436 lines) and
`index.html`, plus the menu bar in `app.py`. A box is ticked only when the
Flutter screen does it **and a test or a run shows it**. "Dropped" means the
feature does not exist in the new app on purpose, with the reason.

Legend: `[x]` done and checked · `[ ]` not yet · `[-]` dropped on purpose.

**Status (audited line by line):** every box below is ticked against a named
test or a run, and a line that could not be shown stays open with the reason.
The audit found five gaps with no test (the live scan table and metrics, the
locked port and form length, the *Connecting…* badge, the session bar, the
offer to empty the page cache) and one that had none for its copy (*What is
sent*); `app/test/audit_gaps_test.dart` now covers them. Wording was also
compared mechanically: all 26 toast messages in the old page appear verbatim in
the new code except four that do not apply (the browser import, "Open the app
itself to choose a PDF", the clipboard fallback, and "That setting could not be
saved"). Descriptive paragraphs under headings were reworded in places, and
"T-TESS" became "your site"; behaviour is what is held equal.

## Behaviour that lives in the page and must move into Dart

These are not screens; they are rules the old UI enforced in JavaScript. Each
becomes tested view-model or domain code.

- [x] **Student ID matching ignores leading zeros** (`sameStudentId`): a bubbled
  `0900011` matches a roster `900011`. Also in `store._bare_id`.
- [x] **Roster walk** (`rosterIndex`, `advanceRoster`, `currentStudent`): which
  student is expected next, kept per class for the life of the app session.
  Skip absent, Start at first student.
- [x] **Auto-save a detected student** (`renderReview` → `saveDetectedStudent`):
  with matching "By bubbled ID", a student sheet with a scanner-read ID, no
  ambiguities, and (no roster or an ID on the roster) is saved without asking.
- [x] Three **student matching modes**: `id` (any order), `roster` (roster order,
  ignores the ID area), `manual` (every sheet asks).
- [x] **Review dialog content** per sheet: title (Confirm NAME / Check the scan /
  Enter the student ID), intro text variants (ambiguities, ID not in class,
  ID read, manual), per-question choices (each option, Blank, Keep X), ID and
  name prefilled from the roster.
- [x] Question count clamp 1–100 on leaving the field, with the message.
- [x] New in Flutter: a key that stops short of the count asks "Use 30 questions /
  Keep 50 questions" the moment it is captured (once per session; keeping is an
  answer). The count only ever goes down, and the field and the remembered
  setting follow. `question_count_screens_test`, `scan_model_test`,
  `question_count_test`.
- [x] Test name saved 400 ms after typing stops.
- [x] Export filename: `class - test.csv`, falling back to `datalink-session`.
- [x] Activity list: protocol lines hidden unless "Show protocol details".
- [x] Toast messages (kept verbatim: they are user-facing copy). Checked by
  comparing every toast string in `app.js` with the new source.
- [x] Item status cut points: Priority < 60 %, Developing < 70 %, else Secure.
- [x] Review rows: the exact problem wording for student_id, faint, multiple,
  session (stale device key), score disagreement, faint sheet, pending review.
- [x] Review-key format `page:field:question:reason` (must equal
  `analysis.review_key`).
- [x] Only *changed* ID/name boxes count as corrections on Apply.
- [x] Ticking a row, or changing its answer, settles it.
- [x] Name box hides when a roster student is chosen; typing an ID fills the
  name from the session's own class roster, never overwriting a typed name.
- [x] Answer-key editor: per-question A–E, changed rows marked, "N answers
  changed. Saving rescores every sheet", confirm before saving.
- [x] Upload picker: Course → Section → Unit → Test, each narrowing the next,
  selections surviving a refresh; draft-run detection switches the button to
  "Add results" by default; "Replace draft results" refreshes the remote draft and asks before replacing.
- [x] Paper: disable Run until a PDF is chosen; key page max = page count;
  key-fix flow requires every unresolved question answered before retry.
- [x] Offer to empty the page cache once per run when over 500 MB.
- [x] Session context bar (name, class, sheet count, time) with Sheets /
  Analysis / Clear; selecting a test in either tab selects it in both.
- [x] Routing: Back works between tabs, sessions and analysis panes.

## Scan
- [x] Connection badge: Disconnected / Connecting… / Ready to scan / Connected ·
  no session / Needs attention
- [x] Port picker (Auto-detect + listed ports), locked while connected
- [x] Test name · Class picker · Student matching (+ help) · Questions per form (+ help)
- [x] Connect and start session / Start scanning session · End session (confirm) ·
  Reset scanner (+ tooltip) · Disconnect
- [x] Metrics: sheets captured, latest answered n / N, session name
- [x] Workflow card: Start a session → Scan the answer key first → Next: NAME …
  (all variants), roster summary line
- [x] Skip absent · Start at first student
- [x] Live scans table (newest first): Key / Student N, name + ID, time, Q1…Qn,
  blank "—" and multiple styling
- [x] Clear view (disabled while a session runs, with explanation)
- [x] Activity list with kinds, Show/Hide protocol details
- [x] Export CSV (Save panel)

## Paper
- [x] Choose PDF (Open panel), file line "name · N pages"
- [x] Test name · Class · Key page · Questions (1–50). Pages / skip-pages: the
  old form never offered them either; the reader supports them
  (`PaperRequest.pages`, `skipPages`).
- [x] Read the sheets · progress bar + message
- [x] New in Flutter: the key page is read on its own first; if it has answers
  through question 30 and none after while the batch says 50, the batch is not
  read, and the page asks "Read as 30 questions / Keep 50 questions".
- [x] New in Flutter, Analysis: a saved test whose key stops short of its count
  (so it cannot be scored) shows "This looks like a 30-question test" with a
  one-press "Score out of 30"; marks students made after question 30 are named
  and need a yes. Never offered for a session still being scanned, and never
  upwards (the answers past the old count were not kept).
- [x] Answer-key-needs-a-hand: explanation, per-question radios with what the
  reader saw, Look at the key sheet, Use these and read the batch, Start over
- [x] Done: message, Open the item analysis, Read another batch
- [x] Page cache size line, Empty the cache (confirm)
- [-] "Paper scanning support" card and Install support: nothing is installed at
  runtime any more.

## Sessions
- [x] List (when, name, class, sheets) with View / Rename / Delete (confirm)
- [x] Refresh · Storage summary and path · Show in Finder
- [x] Delete sessions older than N (preview count, confirm, result toast)
- [x] Detail: title, summary line, scan table with all Q columns
- [x] Click any response to correct it (A–E or Blank), "already what is
  recorded", saved toast
- [x] Export CSV · Export item analysis JSON (disabled with reason when not
  scoreable)
- [x] Close

## Analysis
- [x] Test picker
- [x] Metrics: students, average %, KR-20, items to review
- [x] Priority callout ("Focus first on item(s) …")
- [x] Counts: Priority / Developing / Secure / Flagged
- [x] Item table with bars, filters (All / Priority / Developing / Secure / Flagged)
- [x] Full statistical diagnostics (toggle)
- [x] Student scores table
- [x] Review pane: badge count, empty state, rows, sheet viewer, answer fix,
  Mark all checked / Untick all, Apply corrections, "N checked off and hidden",
  Show them again
- [x] Answer key pane
- [x] Send to T-TESS pane (see Settings)
- [x] Download item analysis JSON
- [x] Error banner "This test cannot be scored"

## Classes
- [x] List (name, students, selected ✓) · Use for scanning · Edit · New class
- [x] Editor: class name, roster as `id, name` lines, validation "Fix roster
  line: …", Save (toast "Saved X with N students"), Delete (confirm)
- [x] Rename carries through to sessions

## Settings
- [x] Connection status, token entry, Connect / Disconnect (confirm)
- [x] Upload address and site address, Save address (https only)
- [x] Destination summary, Refresh tests
- [x] Copy the specification (clipboard)
- [x] "What is sent" card
- [-] Updates card · automatic update check (the store delivers updates)
- [-] "Quit" (Cmd-Q quits) · "Open in Browser" (there is no server)
- [-] localStorage class import (`/api/classes/import`)

## Menu bar (from `app.py`)
- [x] Connect · End session · Reset scanner · Disconnect · Clear view
- [x] Skip student · Start at first student · Show protocol details
- [x] Scan · Paper · Classes · Sessions · Analysis · Settings
- [x] Read paper batch (⌘O) · New class · Edit class
- [x] Export CSV · Export analysis · Open session folder
- [x] Help · Protocol notes · Report an issue
- [ ] About: the standard macOS About panel. Only a run of the app can show it.
- [-] Check for Updates

## Accessibility (applies to every screen)

Checked by `accessibility_test`, `semantics_test`, `keyboard_test`,
`reduce_motion_test` and `palette_test` over every screen, in light and dark.
What a test cannot say is how it *sounds*; a VoiceOver walk by a person is
still worth doing before release.

- [x] Every control has a VoiceOver label; badges announce their count.
  Flutter's labelled-tap-target check passes on all ten screens in both themes;
  the Review badge reads "Review, N items to review".
- [x] Tables expose row and column headers (Semantics). Columns read as
  "Question N"; each pressable cell says whose answer it is and what it holds.
  Each screen has headings to navigate by, and the chosen tab is marked selected.
- [x] Full keyboard path. Tab walks the whole navigation rail, then the page
  (they are separate groups); Space chooses a tab. Escape cancels a dialog,
  Return confirms a harmless one and never a destructive one; the sheet-review
  dialog opens with the cursor in the ID box and Return saves; a pop-up menu and
  a table cell work from the keyboard.
- [x] Contrast in light and dark, status never by colour alone. Every colour pair
  passes WCAG (`palette_test`), Flutter's text-contrast check passes on every
  screen as drawn, and each status pill carries words as well as colour.
- [x] Respects Reduce Motion and increased text size. Dialogs and toasts appear
  at once with Reduce Motion on (nothing in the app loops or moves otherwise);
  every screen has no overflow at 150% and 200% text at 1100 x 760, and the
  window cannot be made smaller than 1000 x 700. The Analysis panes and test
  picker scroll or truncate rather than clip at large sizes.

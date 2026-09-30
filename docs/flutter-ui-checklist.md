# UI parity checklist

Built from a full read of `src/datalink_scanner/webui/app.js` (2,436 lines) and
`index.html`, plus the menu bar in `app.py`. A box is ticked only when the
Flutter screen does it **and a test or a run shows it**. "Dropped" means the
feature does not exist in the new app on purpose, with the reason.

Legend: `[x]` done and checked · `[ ]` not yet · `[-]` dropped on purpose.

## Behaviour that lives in the page and must move into Dart

These are not screens; they are rules the old UI enforced in JavaScript. Each
becomes tested view-model or domain code.

- [ ] **Student ID matching ignores leading zeros** (`sameStudentId`): a bubbled
  `0900011` matches a roster `900011`. Also in `store._bare_id`.
- [ ] **Roster walk** (`rosterIndex`, `advanceRoster`, `currentStudent`): which
  student is expected next, kept per class for the life of the app session.
  Skip absent, Start at first student.
- [ ] **Auto-save a detected student** (`renderReview` → `saveDetectedStudent`):
  with matching "By bubbled ID", a student sheet with a scanner-read ID, no
  ambiguities, and (no roster or an ID on the roster) is saved without asking.
- [ ] Three **student matching modes**: `id` (any order), `roster` (roster order,
  ignores the ID area), `manual` (every sheet asks).
- [ ] **Review dialog content** per sheet: title (Confirm NAME / Check the scan /
  Enter the student ID), intro text variants (ambiguities, ID not in class,
  ID read, manual), per-question choices (each option, Blank, Keep X), ID and
  name prefilled from the roster.
- [ ] Question count clamp 1–100 on leaving the field, with the message.
- [ ] Test name saved 400 ms after typing stops.
- [ ] Export filename: `class - test.csv`, falling back to `datalink-session`.
- [ ] Activity list: protocol lines hidden unless "Show protocol details".
- [ ] Toast messages (kept verbatim: they are user-facing copy).
- [ ] Item status cut points: Priority < 60 %, Developing < 70 %, else Secure.
- [ ] Review rows: the exact problem wording for student_id, faint, multiple,
  session (stale device key), score disagreement, faint sheet, pending review.
- [ ] Review-key format `page:field:question:reason` (must equal
  `analysis.review_key`).
- [ ] Only *changed* ID/name boxes count as corrections on Apply.
- [ ] Ticking a row, or changing its answer, settles it.
- [ ] Name box hides when a roster student is chosen; typing an ID fills the
  name from the session's own class roster, never overwriting a typed name.
- [ ] Answer-key editor: per-question A–E, changed rows marked, "N answers
  changed. Saving rescores every sheet", confirm before saving.
- [ ] Upload picker: Course → Section → Unit → Test, each narrowing the next,
  selections surviving a refresh; draft-run detection switches the button to
  "Update draft" and asks before replacing.
- [ ] Paper: disable Run until a PDF is chosen; key page max = page count;
  key-fix flow requires every unresolved question answered before retry.
- [ ] Offer to empty the page cache once per run when over 500 MB.
- [ ] Session context bar (name, class, sheet count, time) with Sheets /
  Analysis / Clear; selecting a test in either tab selects it in both.
- [ ] Routing: Back works between tabs, sessions and analysis panes.

## Scan
- [ ] Connection badge: Disconnected / Connecting… / Ready to scan / Connected ·
  no session / Needs attention
- [ ] Port picker (Auto-detect + listed ports), locked while connected
- [ ] Test name · Class picker · Student matching (+ help) · Questions per form (+ help)
- [ ] Connect and start session / Start scanning session · End session (confirm) ·
  Reset scanner (+ tooltip) · Disconnect
- [ ] Metrics: sheets captured, latest answered n / N, session name
- [ ] Workflow card: Start a session → Scan the answer key first → Next: NAME …
  (all variants), roster summary line
- [ ] Skip absent · Start at first student
- [ ] Live scans table (newest first): Key / Student N, name + ID, time, Q1…Qn,
  blank "—" and multiple styling
- [ ] Clear view (disabled while a session runs, with explanation)
- [ ] Activity list with kinds, Show/Hide protocol details
- [ ] Export CSV (Save panel)

## Paper
- [ ] Choose PDF (Open panel), file line "name · N pages"
- [ ] Test name · Class · Key page · Questions (1–50) · (pages / skip-pages)
- [ ] Read the sheets · progress bar + message
- [ ] Answer-key-needs-a-hand: explanation, per-question radios with what the
  reader saw, Look at the key sheet, Use these and read the batch, Start over
- [ ] Done: message, Open the item analysis, Read another batch
- [ ] Page cache size line, Empty the cache (confirm)
- [-] "Paper scanning support" card and Install support: nothing is installed at
  runtime any more.

## Sessions
- [ ] List (when, name, class, sheets) with View / Rename / Delete (confirm)
- [ ] Refresh · Storage summary and path · Show in Finder
- [ ] Delete sessions older than N (preview count, confirm, result toast)
- [ ] Detail: title, summary line, scan table with all Q columns
- [ ] Click any response to correct it (A–E or Blank), "already what is
  recorded", saved toast
- [ ] Export CSV · Export item analysis JSON (disabled with reason when not
  scoreable)
- [ ] Close

## Analysis
- [ ] Test picker
- [ ] Metrics: students, average %, KR-20, items to review
- [ ] Priority callout ("Focus first on item(s) …")
- [ ] Counts: Priority / Developing / Secure / Flagged
- [ ] Item table with bars, filters (All / Priority / Developing / Secure / Flagged)
- [ ] Full statistical diagnostics (toggle)
- [ ] Student scores table
- [ ] Review pane: badge count, empty state, rows, sheet viewer, answer fix,
  Mark all checked / Untick all, Apply corrections, "N checked off and hidden",
  Show them again
- [ ] Answer key pane
- [ ] Send to T-TESS pane (see Settings)
- [ ] Download item analysis JSON
- [ ] Error banner "This test cannot be scored"

## Classes
- [ ] List (name, students, selected ✓) · Use for scanning · Edit · New class
- [ ] Editor: class name, roster as `id, name` lines, validation "Fix roster
  line: …", Save (toast "Saved X with N students"), Delete (confirm)
- [ ] Rename carries through to sessions

## Settings
- [ ] Connection status, token entry, Connect / Disconnect (confirm)
- [ ] Upload address and site address, Save address (https only)
- [ ] Destination summary, Refresh tests
- [ ] Copy the specification (clipboard)
- [ ] "What is sent" card
- [-] Updates card · automatic update check (the store delivers updates)
- [-] "Quit" (Cmd-Q quits) · "Open in Browser" (there is no server)
- [-] localStorage class import (`/api/classes/import`)

## Menu bar (from `app.py`)
- [ ] Connect · End session · Reset scanner · Disconnect · Clear view
- [ ] Skip student · Start at first student · Show protocol details
- [ ] Scan · Paper · Classes · Sessions · Analysis · Settings
- [ ] Read paper batch · New class · Edit class
- [ ] Export CSV · Export analysis · Open session folder
- [ ] Help · Protocol notes · Report an issue · About
- [-] Check for Updates

## Accessibility (applies to every screen)
- [ ] Every control has a VoiceOver label; badges announce their count
- [ ] Tables expose row and column headers (Semantics)
- [ ] Full keyboard path: tab strip, dialogs (Esc / Enter), tables, pickers
- [ ] Contrast checked in light and dark; status never conveyed by colour alone
  (the old pills carried text; keep that)
- [ ] Respects Reduce Motion and increased text size

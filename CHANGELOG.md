# Changelog

Starts at 1.9.5. Earlier releases are in the
[tags](https://github.com/dhohnholt/datalink_Mac_OS_interface/tags) and their
commit history.

Two editions are built from this one codebase, and they update on separate
clocks: the Homebrew build updates with `brew upgrade`, and the Mac App Store
build updates only when Apple approves a new submission. An entry says which
edition it changed when it is not both.

## 2.2.0 — App Store edition (not yet released)

A correction to 2.1.0, which could score every sheet of a test with several
versions against version 1.

* Show the full class roster alphabetically in Student scores, including missing results and per-exam Absent checkboxes. Students with scanned but excluded sheets are labeled Needs review instead of being marked absent.

* Check roster coverage before export or sending. Review lists missing students and permits explicit per-exam absence overrides, retained in JSON without inventing scores. Removing the absence blocks sending again; adding a makeup sheet restores normal scoring.

* Restore **Send to your site** for multi-version answer-map sessions, routing them through the existing upload flow and final readiness guard.

* Block final JSON export and sending until scored-item reviews, student IDs, versions, excluded sheets and score totals are resolved. Unscored printed rows retain their confidence data without requiring review.

* Add per-sheet version selectors in Review, including excluded sheets with no version. Assigning or correcting a version saves it and rescores against that version’s CSV key without rescanning.

* Offer A–O in matching-question review and answer correction menus, using the question’s option range in saved reports.

* Verify mixed-version PDF + CSV scoring through saved-session JSON export. Keep sheets with missing versions in saved reports as excluded, refuse an unmarked student sheet as the key when an answer map is missing, and detect unequal matching double marks instead of accepting only the darkest bubble.

* Score uploaded answer-map CSVs against the 50-question + matching form instead of excluding those student sheets with a misleading version error.

* Add a separate **Choose answer map CSV…** button on Paper, available before and after choosing a PDF.

* Fix Flutter test-package validation to accept single A–O matching answers on printed rows 51–65, including scanned keys. Preserve unused rows such as 41–50 as gaps.

* Clarify the DataLink CSV creation instructions in both editions and the legacy Python prompt: vocabulary matching accepts A–O, standard multiple choice uses A–E, and CSV numbers preserve the matching sheet’s printed rows. Include an A–O matching example.

* **Add makeup sheets to a saved session** (Flutter edition). On Paper, choose
  an existing test under **Save results to**, or use **Add sheets** in Sessions,
  then read the absent student’s PDF. The saved key, class and question count
  are reused; no new key sheet is required. Earlier answers, corrections and
  review decisions stay in place, and new page images remain available in
  Review. Duplicate student IDs are refused without changing the session.

## 2.1.0 — App Store edition

* **Several versions of one test in one run** (Flutter edition). Choose the
  scanned PDF and its test package CSV together on the Paper tab. Each student is
  scored on their own bubbled version; item analysis is per item across versions;
  a new **Standards** pane shows the class and each student by standard and by
  section. With answers in the package, key sheets need not be scanned, and any
  that are get checked against it. **Copy prompt** on the Paper tab copies the
  instructions for the assistant that writes the versions. Such a test shows
  Standards in place of Send to your site, which takes one key per test.
  Sessions gain a `package` column and scans a `version` column (both editions'
  stores, so either opens the other's library).
* **The vocabulary quiz and the 50-question + 15-term matching sheet are read**
  (Flutter edition), and saved from the Paper tab with the vocabulary teacher
  guide. Their key decides which rows count; each is filed as a one-version
  package whose sections are the sheet's parts. Matching letters run to O.
* **Multiple-answer keys:** a key row with several bubbles filled is right only
  when a sheet has exactly those bubbles, on every sheet and in both editions. A
  double mark is stored as its letters ("AC"), and editing a sheet in Review now
  keeps them.
* KR-20 uses the population variance of the totals, matching its p×q terms; it
  read slightly high before, most of all for small classes.

* Removed rebuildable macOS compiler caches, Flutter test output, and PyInstaller intermediates while retaining application products, debug symbols, packages, configurations, and documents.


* Removed regenerable, untracked Python bytecode caches from the local workspace.


* Scan review shows the image beside an independently scrolling correction
  panel. Review all scans now sits at the right of the analysis tab buttons.
  The macOS window opens larger by default and remembers its size and position.
  (Flutter edition.)

* Scan viewers now have Previous and Next buttons and a scan counter, so
  reviewing a batch does not require closing each sheet. The editable
  reviewer stays open after saving; moving with unsaved edits offers Save
  and continue, Discard changes, or Stay here. (Flutter edition.)

* View on a saved session now opens its analysis immediately. The Sheets
  button still opens the session’s recorded responses. (Flutter edition.)

* Review now offers all student scans, including sheets with no flagged
  issues. Open any sheet to inspect its image, correct its student details
  or answers, and save to refresh scores. (Flutter edition.)

* Fixed red-tinted scan previews in the sheet viewer. New previews save
  proper grayscale colours; existing affected previews are repaired for
  display without rescanning or changing the stored images. Diagnostic
  images remain untouched. (Flutter edition.)

* Updated the existing-upload message to match the website: another scan can
  add missing students or update matching students. Upload dates now use a
  readable local date and time. (Flutter edition.)

* The student editor can add a missing student to the session’s class roster
  while saving their name and ID. Existing students and roster order are
  preserved; an ID already listed cannot be added twice. (Flutter edition.)

* Every row in Student scores now has an Edit action for correcting the
  student ID or adding a name, even when the sheet has no review flags. The
  editor includes the class roster and scanned sheet when available; Save
  changes persists the details and refreshes the report. (Flutter edition.)

* Improved recognition of scanned 75-question sheets with grey registration
  squares and lighter pencil. Bubble sampling avoids printed centre letters
  and requires enough filled area to keep empty bubbles blank. Verified the
  first classroom batch recognizes all 15 pages (one key and 14 students),
  with weak answers still flagged for review. (Flutter edition.)

* A printable 75-question answer sheet, for when the bubble forms run out.
  **Save answer sheet…** on the Paper tab saves the one-page PDF; print it on
  plain Letter paper at Actual Size. It has lines for name, course, test name
  and period, a bubbled version (1–4) and six-digit student ID, and an ANSWER
  KEY bubble. Pencil or dark pen both read. A paper batch reads these sheets
  alongside AccuScan forms, finds the key sheet by its bubble when asked, scores
  only the chosen version, and flags students who left the version blank.
  Batches now take up to 75 questions; the AccuScan form still holds 50. The
  PDF in `app/assets/` comes from omr_final's `make_answer_sheet.py`, and its
  layout is mirrored in `packages/datalink_core/lib/src/paper/omr/answer_sheet_75.dart`.
  (Flutter edition.)

* Fixed uploads incorrectly reporting that the analysis changed: regenerating
  a report timestamp no longer invalidates unchanged results. Upload tests now
  advance the clock between analysis reads.

* Send to your site defaults to Add results, preserving earlier and finalized
  imports. Replace draft results is a separate action that refreshes and verifies
  the selected test’s draft before confirmation. Failed or stale replacements
  never fall back to adding; stable run IDs still protect duplicate uploads.

* A student scan can now be removed or replaced from the live scanning table
  without ending the session. Rescanning also returns roster-order scanning to
  that student before the replacement sheet is fed.

## 1.9.5

**Both editions**

* No upload address ships with the app any more. It used to default to one
  school's Supabase function and one school's T-TESS site, written into a
  public repository, which meant the App Store edition needed code to suppress
  somebody's personal details rather than simply not having them. A teacher now
  enters their own address in Settings, and is asked once. A test asserts that
  no real address appears in `ttess.py`, so it cannot creep back.
* A re-scored run can replace an existing one on the receiving site
  (`replace_run_id`), instead of arriving as a second record, with a
  `run_not_replaceable` error for a site that has already finalized results.
* A visual pass over the workspace: one colour ramp in place of twenty-five
  one-off greys, lighter greens, 40px controls, 12px cards, and shadows that
  lift a surface rather than float it. Two older responsive faults went with
  it — the tab strip used to overflow and widen the whole document at narrow
  widths, and the field grid stayed two-wide down to 375px.

**App Store edition only**

* First build that Apple will accept. It is sandboxed, signed for
  distribution, and carries the `Info.plist` build metadata PyInstaller does
  not write.
* Updates through the App Store: the in-app updater, the daily check and the
  menu item are all inert there, because a store app that updates itself is a
  rejection.
* Nothing is installed at runtime; OpenCV, NumPy, Pillow and poppler are in the
  bundle.
* The Keychain is read in process rather than through a helper binary.
* For a teacher with no site of their own, Settings carries the full
  specification of what the app sends and what it expects back, with a button
  that copies it.

## Releasing: two things that have gone wrong more than once

Both cost real time, and both look like a working release until something
downstream refuses it.

**The wrong artifact under the right filename.** A build writes to `dist/` or
`AppStore/dist/` under the name the previous, good artifact had. It has
happened three ways: a testable App Store package that is deliberately not
submittable was uploaded instead of the real one and consumed a build number;
and a release run rebuilt a disk image and an installer over a notarized pair
and left them unstapled under the shipping names after its notarization was
interrupted. Keep one artifact per directory, check what is actually in a file
before sending it, and rename anything that must not ship so its name says so.

**Building a disk image at all.** `release.sh` no longer builds one; pass
`--with-dmg` if a release genuinely needs it. Homebrew installs from the tag
tarball and compiles the app locally, so the image is not what anybody here
runs, and the app Homebrew installs is ad-hoc signed and never quarantined —
Apple notarization does nothing for it. The image exists only for someone who
downloads it rather than using brew. Notarization of it has hung for
45 minutes at a stretch.

Notarization, for the avoidable confusion it causes: the App Store build never
needs it, because App Store Connect notarizes during review. A disk image
needs it only if somebody downloads it, and then it needs it regardless of
which certificate signed it. Certificates do not replace notarization; they
are what makes it possible.

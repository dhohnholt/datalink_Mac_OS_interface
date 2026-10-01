# Paper reading: what was measured

Reading a PDF batch is the one part of the port that depends on pixels, so it
was measured against the Python app on the user's own scans (12 PDFs, 221 pages,
11 batches with a usable key page). Only counts are recorded here; the scans,
renders and reports stay outside the repository.

## Renderer

The OMR constants were measured on `pdftoppm` output at 400 dpi. The scans
embed 200 ppi pictures, so every page is enlarged about 2x, and *how* it is
enlarged moves faint marks across the 0.05 blank threshold.

| Renderer | Answers read differently, **not** flagged for review (of ~8,950) |
|---|---|
| CoreGraphics (system), any interpolation setting | 18 |
| `pdf_scan.dart` (poppler's own resampling) | 4 |

The 4 are marks sitting on the threshold, where one grey level flips the Python
reader as well.

What poppler does, found by fitting against its output (`tool/check_render.dart`
prints the fit for any PDF):

* Enlarging: bilinear with the corners pinned, `x * (sw - 1) / (dw - 1)`, where
  `dw` is the page size rounded **down**; the last row and column repeat.
  Intermediate and final values are truncated, not rounded.
* Shrinking (for example a 600 ppi scan): whole-pixel boxes by Bresenham, with
  the size rounded down **plus one**, and the sum divided with a 23-bit
  fixed-point reciprocal.
* Black-and-white pictures use the shrinking sizes.

Against poppler on the real batches the mean difference is 0.1-0.6 grey levels,
dominated by the JPEG decoder. Pages with `/Rotate` are within a pixel (tested,
looser tolerance). Pages that are not a single picture covering the sheet
(visible text, drawing, clipping, a picture in part of the page) are refused
with a message rather than drawn wrongly. Not implemented: CCITT, JBIG2 and
JPEG 2000 pictures.

## Sheet reader

Given identical pixels, the Dart reader and the Python reader agree on all 221
pages: status, student ID, every answer, review flags, row offset and
orientation (confidence within 5e-6). Template matching is coarse-to-fine
instead of OpenCV's FFT; its peak and score agree with `cv2.matchTemplate` on
synthetic goldens (score within 1e-4, OpenCV works in float32).

## Whole pipeline, same PDF, Python (poppler) vs Dart

208 student sheets, 10,400 answers:

* 40 answers differ (0.4%), and **every one** involves a question the reader
  flagged for review on one side or the other. 0 silent differences.
* 14 student IDs differ, and every one contains a `_` or `?` (already sent to
  Review). 0 silent differences.
* One key sheet differed on a single question (a mark on the threshold), which
  moved every score in that batch by one. The key used there was a student's
  sheet standing in for one; a real key is marked boldly.

Speed: 14 pages in about 8 s on 4 isolates (AOT).

## Not carried over

The Python app cached every page at 400 dpi (about 6 MB each, 375 MB for four
batches). Here only a reduced picture (1100 px wide JPEG, about 150 KB) of each
page is kept, for the Review sheet viewer.

## The orientation template

The reader finds a page's orientation and row offset by matching a crop of the
printed form (the student-ID grid and header). The first version of the app used
a crop of the Python edition's reference scan, which carried one student's
bubbled ID. It was replaced with a crop of a clean key sheet scanned on the same
ScanSnap, cut with `packages/datalink_core/tool/make_orient_template.dart`.

Calibration: the old crop was matched against the new sheet's render (score
0.78, the new form sits 47 px lower and 1 px to the left). Row offsets are
measured against the old reference's frame, so the new crop is cut where the old
one's content is: x 59, y 426, and `orientTemplateY0` stays 380.

Checked on the 221 real pages, against the original template:

* orientation: identical on every page; match confidence 0.71 or better
  (mean +0.09), nowhere near the 0.55 cut-off;
* row offset: identical on 148 pages (67%), one pixel different on 72, and two
  on one. A different scan of the same form lands at a different sub-pixel
  position, so some pixel of disagreement is unavoidable; trying fractional
  shifts of the new template did not improve on 67%;
* what that does to answers, Python reader on both: student IDs identical
  everywhere; 61 of about 11,000 answers differ (0.55%), 57 of them on a
  question already flagged for review and 4 not. Flagged answers overall: 805
  (old) against 818 (new); mean margin and mark strength: identical to three
  decimals. The new template is neither better nor worse, only different on the
  marks that sit on the blank threshold, which is the same kind of difference
  the renderer produces;
* the Dart pipeline end to end on one batch: same 15 students, 0 ID differences,
  2 of 750 answers different.

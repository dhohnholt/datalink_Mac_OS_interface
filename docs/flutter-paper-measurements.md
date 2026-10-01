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

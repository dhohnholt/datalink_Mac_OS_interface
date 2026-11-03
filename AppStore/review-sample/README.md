# Sample batch for App Review

`DataLink-Sample-Batch.pdf` is the file to attach under **App Review Information →
Attachment**. It is entirely synthetic: the printed form is from a scan of a key
sheet with the marks taken off, and every mark, ID and score is invented
(`tools/review_sample/make_sample.py`). No real student appears in it.

To review it: open the app, choose **Paper**, choose the PDF, and press **Read
the sheets**. The defaults (answer key on page 1, 50 questions) are right.

## What it should read as

* 14 pages: page 1 is the answer key; pages 2–6 and 8–14 are twelve student
  sheets with the invented IDs 240101–240112; page 7 is the blank back of a
  duplex scan.
* Result: **12 students, class average 75.2%** (lowest 46%, highest 96%),
  KR-20 0.857 (0.871 before 2.1.0 switched to the population variance).
* Two things are left for the reviewer to see in **Review**: sheet 5 has two
  marks on question 7, and sheet 12 has one column of its student ID left empty
  (the ID reads `240?10`).
* Sheet 10 was fed through upside down; it is read correctly anyway.
* The blank page 7 is skipped, and the results say so.

Read with both the Python reader and this app's reader, every answer and every
ID matched what was drawn. If the numbers above ever change, something in the
reader has.

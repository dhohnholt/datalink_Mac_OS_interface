#!/usr/bin/env python3
"""Cut the orientation template out of the reference page.

The sheet reader finds a page's orientation and vertical offset by matching
this crop of the printed form (the student-ID grid and header: rows 380-1000,
columns 60-900 of `reference_page.png`) against the page. Writes it as raw
8-bit grayscale, row by row, 840 x 620 bytes, for the app bundle.

    python3 tools/omr/make_orient_template.py

NOTE: the reference scan is a real student's sheet. This crop includes the ID
digits written and bubbled on it, but not the name box. Review before shipping.
"""

from pathlib import Path

import cv2

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "src" / "datalink_scanner" / "vendor" / "omr" / "reference_page.png"
TARGET = ROOT / "app" / "assets" / "orient_template.gray"


def main() -> None:
    page = cv2.imread(str(SOURCE), cv2.IMREAD_GRAYSCALE)
    crop = page[380:1000, 60:900]
    assert crop.shape == (620, 840), crop.shape
    TARGET.write_bytes(crop.tobytes())
    print(f"wrote {TARGET} ({TARGET.stat().st_size} bytes)")


if __name__ == "__main__":
    main()

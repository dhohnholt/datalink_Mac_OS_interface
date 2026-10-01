#!/usr/bin/env python3
"""Generate the PDF-render golden files from real poppler.

The Dart port draws a scanned page itself (`paper/pdf/pdf_scan.dart`) because
the OMR calibration was measured on poppler's pixels. This script writes small
synthetic scanner-style PDFs, renders each with `pdftoppm`, and stores both,
so the Dart tests can check its output against poppler's.

Every picture is synthetic (shapes and gradients). Nothing is read from the
user's scans, so the output is safe to commit.

Run from the repository root:

    python3 tools/goldens/make_render_goldens.py

Needs poppler (`pdftoppm`), Pillow and NumPy. Writes
`packages/datalink_core/test/goldens/render/`.
"""

from __future__ import annotations

import gzip
import io
import json
import math
import subprocess
import tempfile
import zlib
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "packages" / "datalink_core" / "test" / "goldens" / "render"


def picture(width: int, height: int, mode: str) -> Image.Image:
    """Shapes, a gradient and some text-like strokes, seeded so it is stable."""
    rng = np.random.default_rng(7)
    xs = np.linspace(0, 1, width)[None, :]
    ys = np.linspace(0, 1, height)[:, None]
    base = (235 - 40 * xs - 25 * ys + 1.5 * rng.standard_normal((height, width))).clip(0, 255)
    image = Image.fromarray(base.astype(np.uint8), "L").convert("RGB")
    draw = ImageDraw.Draw(image)
    for i in range(14):
        cx = int(width * (0.15 + 0.07 * i))
        cy = int(height * (0.1 + 0.06 * i))
        draw.ellipse([cx - 14, cy - 9, cx + 14, cy + 9], outline=(30, 90 + 8 * i, 40), width=2)
        draw.rectangle([cx - 30, cy + 20, cx + 30, cy + 26], fill=(20 + 10 * i, 30, 30))
    draw.line([0, 3, width, height // 2], fill=(10, 10, 10), width=3)
    if mode == "L":
        return image.convert("L")
    if mode == "1":
        return image.convert("L").point(lambda v: 255 if v > 150 else 0).convert("1")
    return image


class Writer:
    def __init__(self) -> None:
        self.objects: list[bytes] = []

    def add(self, body: bytes) -> int:
        self.objects.append(body)
        return len(self.objects)

    def build(self, root: int, *, break_xref: bool = False) -> bytes:
        out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
        offsets = []
        for number, body in enumerate(self.objects, 1):
            offsets.append(len(out))
            out += f"{number} 0 obj\n".encode() + body + b"\nendobj\n"
        xref = len(out)
        out += f"xref\n0 {len(self.objects) + 1}\n".encode()
        out += b"0000000000 65535 f \n"
        for offset in offsets:
            shown = 0 if break_xref else offset
            out += f"{shown:010d} 00000 n \n".encode()
        out += (
            f"trailer\n<< /Size {len(self.objects) + 1} /Root {root} 0 R >>\n"
            f"startxref\n{xref + (7 if break_xref else 0)}\n%%EOF\n"
        ).encode()
        return bytes(out)


def stream(dictionary: str, data: bytes) -> bytes:
    return f"<< {dictionary} /Length {len(data)} >>\nstream\n".encode() + data + b"\nendstream"


def make_pdf(
    image: Image.Image,
    width_pt: float,
    height_pt: float,
    *,
    encoding: str,
    interpolate: bool = True,
    rotate: int = 0,
    invisible_text: bool = True,
    break_xref: bool = False,
) -> bytes:
    w = Writer()
    w_, h_ = image.size
    if encoding == "dct":
        buf = io.BytesIO()
        image.save(buf, "JPEG", quality=88)
        cs = "/DeviceGray" if image.mode == "L" else "/DeviceRGB"
        extra = "/Filter /DCTDecode"
        data = buf.getvalue()
        bpc = 8
    elif encoding == "flate":
        data = zlib.compress(np.asarray(image).tobytes())
        cs = "/DeviceGray" if image.mode == "L" else "/DeviceRGB"
        extra = "/Filter /FlateDecode"
        bpc = 8
    elif encoding == "flate1":
        packed = np.packbits(np.asarray(image).astype(np.uint8), axis=1)
        data = zlib.compress(packed.tobytes())
        cs = "/DeviceGray"
        extra = "/Filter /FlateDecode"
        bpc = 1
    else:
        raise ValueError(encoding)
    flag = "/Interpolate true" if interpolate else ""
    im = w.add(stream(
        f"/Type /XObject /Subtype /Image /Width {w_} /Height {h_} /ColorSpace {cs} "
        f"/BitsPerComponent {bpc} {flag} {extra}", data))
    text = " BT 3 Tr /F1 8 Tf 20 20 Td (ocr) Tj ET" if invisible_text else ""
    content = f"q {width_pt} 0 0 {height_pt} 0 0 cm /Im1 Do Q{text}".encode()
    cont = w.add(stream("", content))
    font = w.add(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    pages = len(w.objects) + 2
    page = w.add(
        f"<< /Type /Page /Parent {pages} 0 R /MediaBox [0 0 {width_pt} {height_pt}] "
        f"/Rotate {rotate} /Contents {cont} 0 R "
        f"/Resources << /XObject << /Im1 {im} 0 R >> /Font << /F1 {font} 0 R >> >> >>".encode())
    w.add(f"<< /Type /Pages /Kids [{page} 0 R] /Count 1 >>".encode())
    catalog = w.add(f"<< /Type /Catalog /Pages {pages} 0 R >>".encode())
    return w.build(catalog, break_xref=break_xref)


CASES = [
    # name, picture size, mode, page points (width, height), options
    ("rgb_jpeg_up", (301, 551), "RGB", 108.5, 198.0, dict(encoding="dct")),
    ("gray_jpeg_int", (300, 550), "L", 108.0, 198.0, dict(encoding="dct", interpolate=False)),
    ("rgb_flate", (290, 545), "RGB", 108.5, 198.0, dict(encoding="flate")),
    ("gray_flate", (301, 550), "L", 108.5, 197.5, dict(encoding="flate")),
    ("bilevel", (600, 1095), "1", 108.5, 197.25, dict(encoding="flate1")),
    ("rotated90", (301, 551), "RGB", 108.5, 198.0, dict(encoding="dct", rotate=90)),
    ("broken_xref", (301, 551), "RGB", 108.5, 198.0, dict(encoding="dct", break_xref=True)),
]
DPIS = [400, 150]


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    manifest = []
    for name, (pw, ph), mode, wpt, hpt, opts in CASES:
        pdf = make_pdf(picture(pw, ph, mode), wpt, hpt, **opts)
        (OUT / f"{name}.pdf").write_bytes(pdf)
        entry = {"name": name, "renders": {}}
        for dpi in DPIS:
            with tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / "in.pdf"
                path.write_bytes(pdf)
                subprocess.run(
                    ["pdftoppm", "-r", str(dpi), "-png", "-singlefile", str(path), str(Path(tmp) / "out")],
                    check=True,
                )
                gray = Image.open(Path(tmp) / "out.png").convert("L")
            data = np.asarray(gray)
            file = f"{name}_{dpi}.gray.gz"
            with gzip.open(OUT / file, "wb", compresslevel=9) as stream_:
                stream_.write(data.tobytes())
            entry["renders"][str(dpi)] = {"file": file, "width": data.shape[1], "height": data.shape[0]}
        manifest.append(entry)
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"wrote {len(manifest)} cases to {OUT}")


if __name__ == "__main__":
    main()

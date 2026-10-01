#!/usr/bin/env python3
"""Golden files for the Dart OMR port, from the real Python and OpenCV.

Two kinds, both synthetic:

* bubble decisions: random ink ratios run through `decide_answer` and
  `answer_confidence`, with and without per-option baselines;
* template matching: random-texture pictures with a template planted in them,
  scored by `cv2.matchTemplate(TM_CCOEFF_NORMED)`.

    python3 tools/goldens/make_omr_goldens.py

Writes `packages/datalink_core/test/goldens/omr.json.gz`.
"""

from __future__ import annotations

import gzip
import json
import sys
from pathlib import Path

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src" / "datalink_scanner" / "vendor" / "omr"))
sys.path.insert(0, str(ROOT / "src" / "datalink_scanner" / "vendor"))
from extract_template_a import answer_confidence, decide_answer  # noqa: E402

OPTIONS = "ABCDE"


def decisions(rng: np.random.Generator) -> list[dict]:
    rows = []
    for i in range(4000):
        shade = rng.uniform(0.0, 0.35)
        ratios = {o: float(np.round(shade + rng.choice([0, 0, 0, 0.02, 0.06, 0.15, 0.4]) * rng.uniform(0.2, 1.2) * (rng.random() < 0.5), 4)) for o in OPTIONS}
        if i % 7 == 0:  # near-ties and near-threshold marks
            top = rng.choice(list(OPTIONS))
            ratios[top] += 0.05 + rng.uniform(-0.01, 0.01)
            other = rng.choice(list(OPTIONS))
            ratios[other] += (ratios[top] - shade) * rng.uniform(0.8, 0.9)
        baselines = None
        if i % 3:
            baselines = {o: float(np.round(rng.uniform(0, 0.08), 4)) for o in OPTIONS}
        answer, _ = decide_answer(ratios, option_baselines=baselines)
        rows.append({
            "ratios": [ratios[o] for o in OPTIONS],
            "baselines": None if baselines is None else [baselines[o] for o in OPTIONS],
            "answer": answer,
            "confidence": answer_confidence(ratios, baselines),
        })
    return rows


def matches(rng: np.random.Generator) -> list[dict]:
    out = []
    for case in range(6):
        h, w = int(rng.integers(260, 420)), int(rng.integers(180, 300))
        th, tw = int(rng.integers(50, 90)), int(rng.integers(40, 70))
        image = rng.integers(60, 220, (h, w)).astype(np.uint8)
        image = cv2.GaussianBlur(image, (0, 0), 2.0)
        # structure: stripes and boxes so there is something to correlate with
        for k in range(25):
            x, y = int(rng.integers(0, w - 20)), int(rng.integers(0, h - 20))
            cv2.rectangle(image, (x, y), (x + int(rng.integers(5, 25)), y + int(rng.integers(5, 25))), int(rng.integers(0, 255)), -1)
        ty, tx = int(rng.integers(0, h - th)), int(rng.integers(0, w - tw))
        template = image[ty:ty + th, tx:tx + tw].copy()
        noisy = np.clip(image.astype(int) + rng.integers(-12, 13, image.shape), 0, 255).astype(np.uint8)
        if case % 2:
            noisy = cv2.GaussianBlur(noisy, (0, 0), 1.2)
        result = cv2.matchTemplate(noisy, template, cv2.TM_CCOEFF_NORMED)
        _, best, _, loc = cv2.minMaxLoc(result)
        out.append({
            "image": {"width": w, "height": h, "data": noisy.flatten().tolist()},
            "template": {"width": tw, "height": th, "data": template.flatten().tolist()},
            "score": float(best), "x": loc[0], "y": loc[1],
        })
    return out


def main() -> None:
    rng = np.random.default_rng(20260930)
    data = {"decisions": decisions(rng), "matches": matches(rng)}
    target = ROOT / "packages" / "datalink_core" / "test" / "goldens" / "omr.json.gz"
    with gzip.open(target, "wt", compresslevel=9) as stream:
        json.dump(data, stream, separators=(",", ":"))
    print(f"wrote {target} ({target.stat().st_size} bytes)")


if __name__ == "__main__":
    main()

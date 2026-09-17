#!/usr/bin/env python3
"""
analyze_exam.py — Run the full pipeline on a duplex-scanned batch of
Apperson DataLink 1200 "Template A" answer sheets (the green 50-question,
5-option A-E form) and produce per-student scores + item analysis.

USAGE

    python3 analyze_exam.py path/to/scan.pdf --key-page N

    --key-page N   The page NUMBER (1-indexed, counting every page in the
                    PDF including blank backs) that holds the answer key.
                    Required. If you're not sure, run with --list-pages
                    first to see a thumbnail contact sheet.

    --list-pages   Just render a contact sheet of every page (as
                    contact_sheet.png) and exit, without analyzing
                    anything. Use this to find your key page number and
                    sanity-check the scan before a full run.

    --pages SPEC   Analyze only selected PDF pages. SPEC may be "all",
                    "odd", "even", or a comma-separated list/range such
                    as "1,3,7-15". Useful for front sides of duplex scans.

    --skip-pages SPEC
                    Exclude individual pages or ranges after --pages is
                    applied, for example "4,12-14".

    --dpi N        Rendering resolution (default 400). Don't change this
                    unless you know what you're doing -- the calibration
                    was measured at 400dpi.

OUTPUT (written to ./output/ by default)

    student_scores.csv   One row per student: ID, correct/total, %, etc.
    item_analysis.csv    One row per question: correct answer, % correct,
                          full A-E/blank/multiple distribution, flags for
                          questions missed by >25%/40%/50% of the class.
    run_log.txt           Page-by-page processing notes, including any
                          pages skipped and why -- READ THIS if your
                          student count looks off.

IMPORTANT ASSUMPTIONS

- This script currently only handles ONE physical answer-sheet layout:
  the green "AccuScan" 5-option (A-E) Apperson form calibrated from a
  reference scan bundled alongside this script (reference_page.png).
  If your class uses a different physical answer sheet, those pages
  will be silently skipped -- check run_log.txt for a per-page count.
- Pages with very little ink (blank backs from duplex scanning) are
  auto-skipped.
- The key page must be marked via --key-page; it is NOT auto-detected.

REQUIREMENTS

    pip3 install opencv-python-headless numpy --break-system-packages
    Poppler's pdftoppm must be on your PATH (brew install poppler on Mac).
"""

import argparse
import atexit
from concurrent.futures import ThreadPoolExecutor, as_completed
import csv
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from calibrate_page import calibrate_page, fix_orientation
from extract_template_a import extract_gray_page
from page_selection import parse_page_spec
from analysis_core import class_statistics, item_analysis, score_student, validate_answer_key
from result_schema import build_analysis_result


def pdf_page_count(pdf_path):
    result = subprocess.run(
        ["pdfinfo", pdf_path], check=True, capture_output=True, text=True
    )
    for line in result.stdout.splitlines():
        if line.startswith("Pages:"):
            return int(line.split(":", 1)[1].strip())
    raise ValueError("pdfinfo did not report a page count")


def render_pdf(pdf_path, out_dir, dpi, page_numbers=None, workers=1, progress=None):
    os.makedirs(out_dir, exist_ok=True)
    if page_numbers is None:
        prefix = os.path.join(out_dir, "page")
        subprocess.run(
            ["pdftoppm", "-png", "-r", str(dpi), pdf_path, prefix], check=True
        )
    else:
        def render_one(page):
            prefix = os.path.join(out_dir, f"page-{page:06d}")
            output = f"{prefix}.png"
            if os.path.exists(output):
                return page
            subprocess.run(
                ["pdftoppm", "-png", "-r", str(dpi), "-f", str(page), "-l", str(page),
                 "-singlefile", pdf_path, prefix],
                check=True,
            )
            return page

        with ThreadPoolExecutor(max_workers=max(1, workers)) as pool:
            futures = [pool.submit(render_one, page) for page in sorted(page_numbers)]
            for completed, future in enumerate(as_completed(futures), 1):
                page = future.result()
                if progress:
                    progress(completed, len(futures), page)
    files = sorted(
        f for f in os.listdir(out_dir) if f.startswith("page") and f.endswith(".png")
    )
    paths = [os.path.join(out_dir, f) for f in files]
    if page_numbers is not None:
        wanted = set(page_numbers)
        paths = [path for path in paths if page_number_from_path(path) in wanted]
    return paths


def page_number_from_path(path):
    """Return the 1-indexed PDF page number from pdftoppm's filename."""
    return int(os.path.splitext(os.path.basename(path))[0].replace("page-", ""))


def is_blank_page(gray_img, ink_thresh=170, min_ink_fraction=0.01):
    """Very little dark ink anywhere -> treat as a blank duplex-scan back."""
    ink_fraction = float(np.mean(gray_img < ink_thresh))
    return ink_fraction < min_ink_fraction


def is_template_a(gray_img, min_match_conf=0.55):
    """Does this page's structure match our calibrated Template A form?"""
    _, _, conf = fix_orientation(gray_img)
    return conf >= min_match_conf, conf


def load_json_mapping(path):
    if not path:
        return {}
    with open(path) as stream:
        return json.load(stream)


def apply_corrections(results_by_page, corrections):
    """Apply auditable page-level student ID and answer corrections."""
    applied = []
    for page_text, changes in corrections.items():
        page = int(page_text)
        if page not in results_by_page:
            raise ValueError(f"correction refers to unprocessed page {page}")
        result = results_by_page[page]
        if "student_id" in changes:
            old = result["student_id"]
            result["student_id"] = str(changes["student_id"])
            applied.append({"page": page, "field": "student_id", "old": old, "new": result["student_id"]})
        for question_text, new_answer in changes.get("answers", {}).items():
            question = int(question_text)
            new_answer = str(new_answer).upper()
            if question not in range(1, 51) or new_answer not in "ABCDE":
                raise ValueError(f"invalid correction on page {page}, question {question_text}")
            old = result["answers"][question]
            result["answers"][question] = new_answer
            applied.append({"page": page, "field": f"answer_{question}", "old": old, "new": new_answer})
    return applied


def process_page(path, min_match_conf=0.55, scan_student_id=True):
    page_num = page_number_from_path(path)
    gray = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
    if gray is None:
        raise FileNotFoundError(path)
    if is_blank_page(gray):
        return page_num, "blank", None, None
    oriented, angle, confidence = fix_orientation(gray)
    if confidence < min_match_conf:
        return page_num, "unsupported", None, round(confidence, 2)
    return page_num, "processed", extract_gray_page(
        oriented, angle, confidence, scan_student_id=scan_student_id
    ), confidence


def cache_directory(cache_root, pdf_path, dpi):
    if not cache_root:
        return None
    stat = os.stat(pdf_path)
    identity = f"{os.path.abspath(pdf_path)}:{stat.st_size}:{stat.st_mtime_ns}:{dpi}"
    digest = hashlib.sha256(identity.encode()).hexdigest()[:16]
    path = os.path.join(cache_root, digest)
    os.makedirs(path, exist_ok=True)
    return path


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("pdf_path")
    ap.add_argument("--exam-name", default=None,
                    help="Human-readable test name stored in analysis_result.json")
    ap.add_argument("--question-count", type=int, default=50,
                    help="number of scored questions on the test, from 1 to 50")
    ap.add_argument("--key-page", type=int, default=None,
                     help="1-indexed page number holding the answer key")
    ap.add_argument("--list-pages", action="store_true",
                     help="Render a contact sheet and exit")
    ap.add_argument("--pages", default="all",
                    help='pages to analyze: "all", "odd", "even", or "1,3,7-15"')
    ap.add_argument("--skip-pages", default="",
                    help='pages to exclude after --pages is applied, e.g. "4,12-14"')
    ap.add_argument("--key-overrides", default=None,
                    help='JSON file mapping question numbers to corrected answers')
    ap.add_argument("--corrections", default=None,
                    help='JSON file containing student ID or answer corrections by page')
    ap.add_argument("--flag-thresholds", default="25,40,50",
                    help='comma-separated percentages missed used to flag items')
    ap.add_argument("--dpi", type=int, default=400)
    ap.add_argument("--thumbnail-dpi", type=int, default=72,
                    help="contact-sheet render resolution, default 72")
    ap.add_argument("--workers", type=int, default=min(4, os.cpu_count() or 1),
                    help="parallel render/extraction workers, default up to 4")
    ap.add_argument("--cache-dir", default=None,
                    help="optional persistent directory for rendered-page reuse")
    ap.add_argument("--run-id", default=None,
                    help="optional integration-provided identifier for this analysis run")
    ap.add_argument("--skip-id-scan", action="store_true",
                    help="do not read or flag student IDs; identify students by PDF page")
    ap.add_argument("--out", default="output")
    ap.add_argument("--work", default=None,
                    help="scratch dir for rendered pages (default: unique temporary directory)")
    args = ap.parse_args()

    if args.question_count not in range(1, 51):
        ap.error("--question-count must be between 1 and 50")

    if args.work is None:
        args.work = tempfile.mkdtemp(prefix="exam_analyzer_")
        atexit.register(shutil.rmtree, args.work, ignore_errors=True)

    os.makedirs(args.out, exist_ok=True)
    log_lines = []

    def log(msg):
        print(msg)
        log_lines.append(msg)

    try:
        total_pages = pdf_page_count(args.pdf_path)
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(f"ERROR: could not inspect PDF: {exc}")
        sys.exit(2)

    if args.list_pages:
        log(f"Rendering all {total_pages} pages at {args.thumbnail_dpi}dpi for preview...")
        page_files = render_pdf(args.pdf_path, args.work, args.thumbnail_dpi)
        log(f"{len(page_files)} pages rendered.")
        from PIL import Image
        cols = 6
        thumbs = [Image.open(f) for f in page_files]
        tw = min(220, thumbs[0].width)
        th = round(thumbs[0].height * (tw / thumbs[0].width))
        rows = (len(thumbs) + cols - 1) // cols
        sheet = Image.new("RGB", (tw * cols, th * rows), "white")
        for i, im in enumerate(thumbs):
            sheet.paste(im.resize((tw, th)), ((i % cols) * tw, (i // cols) * th))
        sheet.save(os.path.join(args.out, "contact_sheet.png"))
        log(f"Saved {args.out}/contact_sheet.png -- find your key page number, "
            f"then re-run with --key-page N")
        return

    if args.key_page is None:
        print("ERROR: --key-page is required (use --list-pages first if unsure)")
        sys.exit(1)

    try:
        selected_pages = parse_page_spec(args.pages, total_pages)
        skipped_by_user = parse_page_spec(args.skip_pages, total_pages)
    except ValueError as exc:
        print(f"ERROR: invalid page selection: {exc}")
        sys.exit(2)

    selected_pages -= skipped_by_user
    if not selected_pages:
        print("ERROR: the page selection contains no pages to analyze")
        sys.exit(2)
    if args.key_page not in selected_pages:
        print(f"ERROR: key page {args.key_page} is excluded by the page selection")
        sys.exit(2)

    skipped_by_selection = sorted(
        set(range(1, total_pages + 1)) - selected_pages
    )
    log(f"Selected {len(selected_pages)} of {total_pages} pages for analysis.")
    if skipped_by_selection:
        log(f"Skipped by page selection: {len(skipped_by_selection)} pages -> "
            f"{skipped_by_selection}")

    render_dir = cache_directory(args.cache_dir, args.pdf_path, args.dpi) or args.work
    log(f"Rendering {len(selected_pages)} selected pages at {args.dpi}dpi "
        f"with {args.workers} worker(s)...")
    def render_progress(done, total, page):
        print(f"  Rendered {done}/{total} (PDF page {page})", flush=True)
    page_files = render_pdf(
        args.pdf_path, render_dir, args.dpi, selected_pages,
        workers=args.workers, progress=render_progress,
    )
    log(f"{len(page_files)} selected pages rendered.")

    # --- Classify every page ---
    results_by_page = {}
    skipped_blank, skipped_not_a, processed = [], [], []

    with ThreadPoolExecutor(max_workers=max(1, args.workers)) as pool:
        futures = {
            pool.submit(process_page, path, 0.55, not args.skip_id_scan): path
            for path in page_files
        }
        for done, future in enumerate(as_completed(futures), 1):
            page_num, status, result, confidence = future.result()
            print(f"  Read {done}/{len(futures)} (PDF page {page_num}: {status})", flush=True)
            if status == "blank":
                skipped_blank.append(page_num)
            elif status == "unsupported":
                skipped_not_a.append((page_num, confidence))
            else:
                results_by_page[page_num] = result
                processed.append(page_num)

    processed.sort()
    skipped_blank.sort()
    skipped_not_a.sort()

    log(f"\nProcessed as Template A: {len(processed)} pages")
    log(f"Skipped as blank: {len(skipped_blank)} pages -> {skipped_blank}")
    if skipped_not_a:
        log(f"Skipped as NOT Template A (unsupported layout): "
            f"{[p for p, c in skipped_not_a]}")
        log("  These pages were not analyzed. If your class uses more than "
            "one answer-sheet layout, those students are missing from the "
            "results below.")

    if args.key_page not in results_by_page:
        print(f"ERROR: page {args.key_page} was not processed as a valid "
              f"Template A sheet (see log above). Check --list-pages output.")
        sys.exit(1)

    try:
        corrections = load_json_mapping(args.corrections)
        applied_corrections = apply_corrections(results_by_page, corrections)
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as exc:
        print(f"ERROR: could not apply corrections: {exc}")
        sys.exit(2)

    answer_key = results_by_page[args.key_page]["answers"]
    try:
        key_overrides = load_json_mapping(args.key_overrides)
        for question_text, new_answer in key_overrides.items():
            question = int(question_text)
            new_answer = str(new_answer).upper()
            if question not in range(1, args.question_count + 1) or new_answer not in "ABCDE":
                raise ValueError(f"invalid key override {question_text!r}: {new_answer!r}")
            answer_key[question] = new_answer
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as exc:
        print(f"ERROR: could not apply answer-key overrides: {exc}")
        sys.exit(2)

    key_validation = validate_answer_key(answer_key, args.question_count)
    if not key_validation["valid"]:
        review_path = os.path.join(args.out, "answer_key_review.json")
        with open(review_path, "w") as f:
            json.dump({
                "key_page": args.key_page,
                "answers": answer_key,
                "validation": key_validation,
                "confidence": results_by_page[args.key_page].get("answer_confidence", {}),
            }, f, indent=2)
        unresolved = sorted(key_validation["invalid"])
        log(f"\nERROR: answer key has unresolved question(s): {unresolved}")
        log(f"Review {review_path}, provide corrections with --key-overrides, and rerun.")
        with open(os.path.join(args.out, "run_log.txt"), "w") as f:
            f.write("\n".join(log_lines))
        sys.exit(2)

    students = {pg: r for pg, r in results_by_page.items() if pg != args.key_page}
    log(f"\nScoring {len(students)} students against the key on page {args.key_page}...")
    if args.skip_id_scan:
        log("Student ID scanning was skipped; students are identified by PDF page.")

    scores = {}
    for pg, r in students.items():
        s = score_student(r["answers"], answer_key, args.question_count)
        scores[pg] = {"student_id": r["student_id"], **s}

    try:
        flag_thresholds = tuple(int(value.strip()) for value in args.flag_thresholds.split(","))
        if not flag_thresholds or any(value < 0 or value > 100 for value in flag_thresholds):
            raise ValueError
    except ValueError:
        print("ERROR: --flag-thresholds must contain percentages from 0 to 100")
        sys.exit(2)
    analysis = item_analysis(
        [r["answers"] for r in students.values()], answer_key,
        question_count=args.question_count,
        flag_thresholds=flag_thresholds,
    )

    # --- Write CSVs ---
    scores_path = os.path.join(args.out, "student_scores.csv")
    with open(scores_path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["Page", "Student ID", "Correct", "Total", "Percentage",
                     "Blank", "Multiple", "Missed Questions"])
        for pg, s in sorted(scores.items(), key=lambda kv: -kv[1]["percentage"]):
            w.writerow([pg, s["student_id"], s["correct"], args.question_count, f'{s["percentage"]}%',
                        s["blank"], s["multiple"],
                        ";".join(str(q) for q in s["missed_questions"])])

    analysis_path = os.path.join(args.out, "item_analysis.csv")
    with open(analysis_path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["Question", "Correct Answer", "N Correct", "% Correct", "Difficulty",
                     "Point Biserial", "Upper-Lower Discrimination",
                     "A %", "B %", "C %", "D %", "E %", "Blank %", "Multiple %",
                     "Most Common Wrong", *[f"Flag >{value}% missed" for value in flag_thresholds]])
        for q in range(1, args.question_count + 1):
            a = analysis[q]
            d = a["distribution"]
            w.writerow([q, a["correct_answer"], a["n_correct"], a["pct_correct"],
                        a["difficulty"], a["point_biserial"], a["upper_lower_discrimination"],
                        d["A"]["pct"], d["B"]["pct"], d["C"]["pct"], d["D"]["pct"], d["E"]["pct"],
                        d["BLANK"]["pct"], d["MULTIPLE"]["pct"], a["most_common_wrong"] or "",
                        *["YES" if a["flags"][f"missed_{value}"] else "" for value in flag_thresholds]])

    stats = class_statistics(scores, analysis, args.question_count)
    if scores:
        log(f"\nClass average: {stats['mean'] / args.question_count * 100:.1f}%  "
            f"(min {stats['minimum'] / args.question_count * 100:.1f}%, "
            f"max {stats['maximum'] / args.question_count * 100:.1f}%)")

    review_items = []
    for page, result in results_by_page.items():
        if page == args.key_page:
            continue
        if (not args.skip_id_scan and
                ("_" in result["student_id"] or "?" in result["student_id"])):
            review_items.append({"page": page, "field": "student_id", "value": result["student_id"]})
        for question, confidence in result.get("answer_confidence", {}).items():
            if question <= args.question_count and confidence["needs_review"]:
                review_items.append({
                    "page": page, "field": "answer", "question": question,
                    "value": result["answers"][question], "confidence": confidence,
                })

    with open(os.path.join(args.out, "review_items.json"), "w") as f:
        json.dump(review_items, f, indent=2)
    with open(os.path.join(args.out, "analysis_summary.json"), "w") as f:
        json.dump({
            "class_statistics": stats,
            "selected_pages": sorted(selected_pages),
            "processed_pages": processed,
            "skipped_blank": skipped_blank,
            "skipped_unsupported": skipped_not_a,
            "applied_corrections": applied_corrections,
            "review_item_count": len(review_items),
            "student_id_scanning": not args.skip_id_scan,
            "question_count": args.question_count,
        }, f, indent=2)

    integration_result = build_analysis_result(
        pdf_path=args.pdf_path,
        exam_name=args.exam_name,
        key_page=args.key_page,
        selected_pages=selected_pages,
        processed_pages=processed,
        skipped_blank=skipped_blank,
        skipped_unsupported=skipped_not_a,
        answer_key=answer_key,
        students=students,
        scores=scores,
        analysis=analysis,
        stats=stats,
        review_items=review_items,
        applied_corrections=applied_corrections,
        flag_thresholds=flag_thresholds,
        run_id=args.run_id,
        scan_student_ids=not args.skip_id_scan,
        question_count=args.question_count,
    )
    integration_path = os.path.join(args.out, "analysis_result.json")
    with open(integration_path, "w") as f:
        json.dump(integration_result, f, indent=2)

    with open(os.path.join(args.out, "run_log.txt"), "w") as f:
        f.write("\n".join(log_lines))

    print(f"\nWrote {scores_path}")
    print(f"Wrote {analysis_path}")
    print(f"Integration JSON: {integration_path}")
    print(f"Full log: {os.path.join(args.out, 'run_log.txt')}")

    shutil.rmtree(args.work, ignore_errors=True)


if __name__ == "__main__":
    main()

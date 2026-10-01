"""Builds the App Review sample batch: 14 pages of answer sheets, all invented.

    python3 tools/review_sample/make_sample.py <scan of a marked key sheet.pdf> <output folder>

The printed form comes from a scan of a key sheet (one question marked per
row, and nothing that names a student). The marks are taken off it, then every
mark, ID and score on the result is made up here: nothing about a real student
is used. Writes DataLink-Sample-Batch.pdf and truth.json (what each page should
read as).

Specific to the scan it was made from: DX and DY (where this render sits
against the calibration frame, found by matching) and the rectangles that wipe
the handwriting and stamps. Needs poppler, OpenCV, NumPy and Pillow."""
import cv2, numpy as np, json, random, subprocess, sys, os
from PIL import Image

SOURCE, OUT = sys.argv[1], sys.argv[2]
os.makedirs(OUT, exist_ok=True)
subprocess.run(['pdftoppm', '-png', '-r', '400', '-singlefile', SOURCE, os.path.join(OUT, 'form')], check=True)
base = cv2.imread(os.path.join(OUT, 'form.png'))  # 2406 x 4400, BGR
DX, DY = -1, 47                                   # this render vs the calibration frame
LEFT = [279.2, 398.4, 517.6, 636.8, 756.0]
RIGHT = [1126.0, 1240.4, 1354.8, 1469.2, 1583.6]
ROW0, SP = 1150.0 + DY, 109.3
ID_COLS = [294.2, 414.8, 535.1, 656.1, 776.0, 895.8]
ID_ROW0, ID_SP = 465.8 + DY, 63.13

def bubble_xy(q, j):
    cols = LEFT if q <= 25 else RIGHT
    row = (q - 1) if q <= 25 else (q - 26)
    return cols[j] + DX, ROW0 + row * SP

def ink(img, x, y, r=30):
    g = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    return float((g[int(y - r):int(y + r), int(x - r):int(x + r)] < 170).mean())

# ---- 1. take the marks off the form -------------------------------------
clean = base.copy()
marked = {}
# What an unmarked bubble reads, per option, in a shaded and an unshaded group
# (the printed letters carry different amounts of ink). Rows 31-50 have no marks.
def group_shaded(q):
    return ((q - 1) // 5) % 2 == 1 if q <= 25 else ((q - 26) // 5) % 2 == 0
def rows_of(shaded):
    return [q for q in range(31, 51) if group_shaded(q) == shaded]
baseline = {sh: [float(np.mean([ink(base, *bubble_xy(q, j)) for q in rows_of(sh)])) for j in range(5)] for sh in (False, True)}
for q in range(1, 51):
    adj = [ink(base, *bubble_xy(q, j)) - baseline[group_shaded(q)][j] for j in range(5)]
    m = int(np.argmax(adj))
    if adj[m] > 0.08:
        marked[q] = m
print('marked rows', len(marked), sorted(marked.items())[:6], '...')
def donor_rows(q, j):
    half = 0 if q <= 25 else 25
    group = (q - 1 - half) // 5
    rows = [half + group * 5 + k + 1 for k in range(5)]
    return [r for r in rows if r != q and marked.get(r) != j]
for q, j in marked.items():
    x, y = bubble_xy(q, j)
    half_ = 0 if q <= 25 else 25
    centre = half_ + ((q - 1 - half_) // 5) * 5 + 3          # the middle row of its group
    d = sorted(donor_rows(q, j), key=lambda r: abs(r - centre))
    assert d, (q, j)
    dx_, dy_ = bubble_xy(d[0], j)
    hy, hx = 40, 64            # short enough to leave a shaded box's edge lines alone
    patch = base[int(round(dy_)) - hy:int(round(dy_)) + hy, int(round(dx_)) - hx:int(round(dx_)) + hx]
    clean[int(round(y)) - hy:int(round(y)) + hy, int(round(x)) - hx:int(round(x)) + hx] = patch
print('marks removed from', len(marked), 'rows')

def inpaint(img, rect, thresh=165, grow=5):
    x0, y0, x1, y1 = rect
    sub = img[y0:y1, x0:x1]
    g = cv2.cvtColor(sub, cv2.COLOR_BGR2GRAY)
    mask = (g < thresh).astype(np.uint8) * 255
    mask = cv2.dilate(mask, np.ones((grow, grow), np.uint8))
    img[y0:y1, x0:x1] = cv2.inpaint(sub, mask, 6, cv2.INPAINT_TELEA)
# handwritten answers beside the rows, the school name, the stamped KEY 30
inpaint(clean, (835, 1150, 940, 3950), thresh=185, grow=7)
inpaint(clean, (1690, 1150, 1830, 3950), thresh=200, grow=7)
# The school-name handwriting: cover it with clean pixels from the same column.
tile = clean[2850:3300, 2140:2236].copy()
clean[1650:2100, 2140:2236] = tile
clean[2100:2550, 2140:2236] = tile
inpaint(clean, (830, 3860, 910, 4100), thresh=200, grow=7)
# the Key and Rescore boxes at the top were marked on the original
for rect in [(365, 170, 485, 235), (1095, 170, 1220, 235)]:
    inpaint(clean, rect, thresh=150, grow=5)
cv2.imwrite(os.path.join(OUT, 'form_without_marks.png'), clean)

# ---- 2. the invented class ----------------------------------------------
random.seed(20260930)
QUESTIONS = 50
KEY = [random.choice('ABCDE') for _ in range(QUESTIONS)]
STUDENTS = [
    ('240101', 0.92), ('240102', 0.84), ('240103', 0.76), ('240104', 0.68), ('240105', 0.88),
    ('240106', 0.60), ('240107', 0.80), ('240108', 0.72), ('240109', 0.96), ('240110', 0.64),
    ('240111', 0.78), ('240112', 0.52),
]

def answers_for(skill):
    out = []
    for k in KEY:
        if random.random() < skill: out.append(k)
        else: out.append(random.choice([c for c in 'ABCDE' if c != k]))
    return out

rng = np.random.default_rng(7)
def pencil(img, cx, cy, rx, ry):
    """A soft grey mark, a little off-centre, a little tilted."""
    layer = np.zeros(img.shape[:2], np.uint8)
    jx, jy = rng.normal(0, 2.2), rng.normal(0, 2.0)
    angle = rng.normal(0, 6)
    cv2.ellipse(layer, (int(cx + jx), int(cy + jy)), (int(rx * rng.uniform(.9, 1.1)), int(ry * rng.uniform(.9, 1.15))),
                angle, 0, 360, 255, -1)
    layer = cv2.GaussianBlur(layer, (0, 0), 1.6).astype(np.float32) / 255
    texture = 0.78 + 0.22 * rng.random(layer.shape).astype(np.float32)
    alpha = np.clip(layer * texture, 0, 1)[..., None]
    tone = np.array([62, 60, 58], np.float32)             # BGR graphite
    img[:] = (img * (1 - alpha * 0.93) + tone * alpha * 0.93).astype(np.uint8)

def sheet(student_id, ans, double=None, blank=None, skip_id_digit=None):
    img = clean.copy()
    for q in range(1, QUESTIONS + 1):
        if blank == q: continue
        if double == q:
            # Two answers pressed in equally (D and E: their printed letters carry
            # a similar amount of ink, so neither looks the heavier).
            for j in (3, 4):
                cx, cy = bubble_xy(q, j)
                pencil(img, cx, cy, 25, 14)
            continue
        j = 'ABCDE'.index(ans[q - 1])
        cx, cy = bubble_xy(q, j)
        pencil(img, cx, cy, 25, 14)
    if student_id:
        for i, ch in enumerate(student_id):
            if skip_id_digit == i: continue
            pencil(img, ID_COLS[i] + DX, ID_ROW0 + int(ch) * ID_SP, 29, 11)
    return img

pages, truth = [], []
pages.append(sheet(None, KEY)); truth.append(dict(page=1, role='key', answers=KEY))
order = list(range(len(STUDENTS)))
page_no = 2
for n, i in enumerate(order):
    sid, skill = STUDENTS[i]
    ans = answers_for(skill)
    kw = {}
    if sid == '240104': kw['double'] = 7             # a double mark
    if sid == '240110': kw['skip_id_digit'] = 3      # an ID with one column left empty
    img = sheet(sid, ans, **kw)
    upside_down = sid == '240108'                    # fed through the other way up
    if upside_down: img = cv2.rotate(img, cv2.ROTATE_180)
    pages.append(img)
    got = list(ans)
    if 'blank' in kw: got[kw['blank'] - 1] = ''
    if 'double' in kw: got[kw['double'] - 1] = '*'
    shown = sid if 'skip_id_digit' not in kw else sid[:kw['skip_id_digit']] + '?' + sid[kw['skip_id_digit'] + 1:]
    truth.append(dict(page=page_no, role='student', id=shown, true_id=sid, answers=got, upside_down=upside_down))
    page_no += 1
    if n == 4:                                        # the blank back of a duplex scan
        pages.append(np.full_like(clean, 252))
        truth.append(dict(page=page_no, role='blank'))
        page_no += 1
json.dump(dict(questions=QUESTIONS, key=KEY, pages=truth), open(os.path.join(OUT, 'truth.json'), 'w'), indent=1)

# ---- 3. a scanner-style PDF: 200 ppi colour JPEG pages ------------------------
imgs = []
for p in pages:
    small = cv2.resize(p, (1203, 2200), interpolation=cv2.INTER_AREA)
    imgs.append(Image.fromarray(cv2.cvtColor(small, cv2.COLOR_BGR2RGB)))
imgs[0].save(os.path.join(OUT, 'DataLink-Sample-Batch.pdf'), 'PDF', resolution=200.0, save_all=True, append_images=imgs[1:], quality=78)
print('pages', len(imgs))

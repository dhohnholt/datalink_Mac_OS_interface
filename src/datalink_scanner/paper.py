"""Reading answer sheets from a PDF, for when the DataLink is not available.

A batch scanned on an ordinary document scanner — a ScanSnap, a copier — goes
through the same pipeline the omr_final project uses, and the answers it reads
are written into the library as an ordinary session. From that point nothing
downstream knows the difference: Sessions, Review, Answer key, Item analysis
and Send to T-TESS all work on it exactly as they do on a DataLink capture,
and the item analysis is computed by the same vendored maths.

Three things are deliberate here:

* The pipeline runs as a subprocess rather than an import. It needs OpenCV and
  NumPy, which are a 154 MB optional extra, and keeping them out of the app's
  own process means a crash reading one bad page cannot take the window down.
* The rendered pages are cached, because re-rendering a 40-page batch at
  400 dpi is slow — and that cache is what grows, so it is reported and can be
  emptied.
* A GUI app inherits a bare PATH, so Homebrew's pdftoppm has to be found and
  passed down explicitly, or every run fails with "No such file".
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

from . import paths


PACKAGES = ("opencv-python-headless", "numpy", "Pillow")
# A frozen app has no interpreter to spawn — sys.executable is the app itself,
# and running it with -c would just open a second window. So it re-enters
# itself behind this flag instead, and the entry point dispatches on it.
RUN_FLAG = "--run-omr"
PROBE_FLAG = "--probe"
# Imported in a subprocess rather than here: this module must stay importable
# with none of them installed.
PROBE = "import cv2, numpy, PIL; print(cv2.__version__)"

# Where poppler ends up, for a process whose PATH is just /usr/bin:/bin.
BINARY_HINTS = ("/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin")
POPPLER_TOOLS = ("pdftoppm", "pdfinfo")

SUPPORT_DIRNAME = "paper-support"
CACHE_DIRNAME = "paper-cache"
# Roughly a term of 40-page batches at 400 dpi before anyone is asked anything.
CACHE_WARN_BYTES = 500 * 1024 * 1024

DEFAULT_DPI = 400
MAX_QUESTIONS = 50
INSTALL_TIMEOUT_SECONDS = 1800
RUN_TIMEOUT_SECONDS = 3600

_PROGRESS = re.compile(r"(Rendered|Read)\s+(\d+)/(\d+)")


class PaperError(RuntimeError):
    """A failure worth showing the teacher, in their words."""


# ------------------------------------------------------------------ places


def vendor_root() -> Path:
    return Path(__file__).resolve().parent / "vendor"


def pipeline_script() -> Path:
    return vendor_root() / "omr" / "analyze_exam.py"


def support_dir() -> Path:
    """Where the optional packages are installed.

    Application Support rather than the virtualenv: `brew upgrade` replaces
    the virtualenv wholesale, and a 154 MB download should not have to be
    repeated every time the app is updated.
    """
    override = os.environ.get("DATALINK_PAPER_SUPPORT")
    if override:
        return Path(override).expanduser()
    return paths.APP_SUPPORT_DIR / SUPPORT_DIRNAME


def cache_root(capture_dir=None) -> Path:
    """Rendered pages, beside the sessions so --capture-dir isolates them."""
    return paths.capture_root(capture_dir) / CACHE_DIRNAME


def frozen() -> bool:
    return bool(getattr(sys, "frozen", False))


def bundled_helpers() -> Path | None:
    """Where the disk-image build keeps its own copy of the poppler tools.

    A Mac that cannot install Homebrew — a managed laptop behind a filter —
    has no pdftoppm at all, so the .dmg carries one.
    """
    if not frozen():
        return None
    helpers = Path(sys.executable).resolve().parent.parent / "Helpers"
    return helpers if helpers.is_dir() else None


def tool_path(name: str) -> str | None:
    helpers = bundled_helpers()
    if helpers is not None and os.access(helpers / name, os.X_OK):
        return str(helpers / name)
    found = shutil.which(name)
    if found:
        return found
    for directory in BINARY_HINTS:
        candidate = Path(directory) / name
        if os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def pipeline_command() -> list[str]:
    """How to start the sheet reader, frozen or not."""
    if frozen():
        return [sys.executable, RUN_FLAG]
    return [sys.executable, str(pipeline_script())]


def run_pipeline(arguments: list[str]) -> int:
    """Run the vendored reader in this process. Only ever called by the flag.

    The vendored modules import each other by plain name, the way they do in
    the project they came from, so their directories go on the path rather
    than being rewritten into package imports.
    """
    if arguments and arguments[0] == PROBE_FLAG:
        import cv2  # noqa: F401  - the probe is the import

        sys.stdout.write(cv2.__version__)
        return 0
    # The vendored reader looks up pdftoppm and pdfinfo on PATH. The caller
    # sets one, but this must not depend on it: a frozen app carries its own
    # copies and should find them however it was started.
    helpers = bundled_helpers()
    if helpers is not None:
        os.environ["PATH"] = os.pathsep.join(
            [str(helpers), os.environ.get("PATH", "")]
        ).strip(os.pathsep)
    for entry in (str(vendor_root() / "omr"), str(vendor_root())):
        if entry not in sys.path:
            sys.path.insert(0, entry)
    import analyze_exam

    sys.argv = ["analyze_exam.py", *arguments]
    analyze_exam.main()
    return 0


def environment() -> dict:
    """PYTHONPATH for the vendored modules and the optional packages, and a
    PATH that actually contains poppler."""
    env = dict(os.environ)
    entries = [
        str(support_dir()),
        str(vendor_root()),
        str(vendor_root() / "omr"),
    ]
    existing = env.get("PYTHONPATH", "")
    if existing:
        entries.append(existing)
    env["PYTHONPATH"] = os.pathsep.join(entries)
    helpers = bundled_helpers()
    path_entries = ([str(helpers)] if helpers else []) + list(BINARY_HINTS)
    path_entries += env.get("PATH", "").split(os.pathsep)
    env["PATH"] = os.pathsep.join(dict.fromkeys(entry for entry in path_entries if entry))
    env["PYTHONUNBUFFERED"] = "1"
    return env


# ------------------------------------------------------- what is installed


def missing_tools() -> list[str]:
    return [name for name in POPPLER_TOOLS if tool_path(name) is None]


def packages_ready(runner=subprocess.run) -> tuple[bool, str | None]:
    probe = (
        [sys.executable, RUN_FLAG, PROBE_FLAG] if frozen()
        else [sys.executable, "-c", PROBE]
    )
    try:
        result = runner(
            probe,
            capture_output=True,
            text=True,
            env=environment(),
            timeout=120,
        )
    except (OSError, subprocess.SubprocessError):
        return False, None
    if result.returncode != 0:
        return False, None
    return True, (result.stdout or "").strip() or None


def pip_available(runner=subprocess.run) -> bool:
    """A PyInstaller build has no pip, so it cannot install anything.

    Asked without this guard it would run `<the app> -m pip`, which opens a
    second window rather than answering the question.
    """
    if frozen():
        return False
    try:
        result = runner(
            [sys.executable, "-m", "pip", "--version"],
            capture_output=True,
            text=True,
            timeout=120,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return result.returncode == 0


def status(runner=subprocess.run) -> dict:
    """Everything the Paper scan page needs to know before it offers to run."""
    ready, version = packages_ready(runner)
    tools = missing_tools()
    missing = []
    if not ready:
        missing.append("packages")
    if tools:
        missing.append("poppler")
    return {
        "ready": not missing,
        "missing": missing,
        "opencv_version": version,
        "packages": list(PACKAGES),
        "poppler_missing": tools,
        "support_dir": str(support_dir()),
        "can_install_packages": pip_available(runner) if not ready else True,
        "download_mb": 51,
        "installed_mb": 154,
    }


def _stream(command: list[str], on_line=None, timeout: float = 600.0, cwd=None) -> tuple[int, str]:
    """Run a command, passing each output line on as it arrives."""
    lines: list[str] = []
    try:
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
            text=True,
            bufsize=1,
            env=environment(),
            cwd=str(cwd) if cwd else None,
        )
    except OSError as exc:
        raise PaperError(f"Could not start {Path(command[0]).name}: {exc}") from None
    try:
        assert process.stdout is not None
        for line in process.stdout:
            line = line.rstrip()
            lines.append(line)
            if on_line is not None:
                on_line(line)
        process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        process.kill()
        raise PaperError("The pipeline was still running after an hour and was stopped.") from None
    return process.returncode, "\n".join(lines)


def install_packages(on_line=None, runner=None) -> str:
    """Install OpenCV, NumPy and Pillow into the app's own support directory."""
    if not pip_available():
        raise PaperError(
            "This build has no pip, so it cannot install the packages itself. "
            "Install DataLink Scanner with Homebrew to use paper scanning, or "
            f"install {', '.join(PACKAGES)} for {sys.executable} yourself."
        )
    target = support_dir()
    try:
        target.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise PaperError(f"Could not create {target}: {exc}") from None
    command = [
        sys.executable, "-m", "pip", "install",
        "--upgrade", "--target", str(target), *PACKAGES,
    ]
    code, transcript = _stream(command, on_line, timeout=INSTALL_TIMEOUT_SECONDS)
    if code != 0:
        raise PaperError(f"Installing the packages failed.\n\n{_tail(transcript)}")
    ready, _ = packages_ready()
    if not ready:
        raise PaperError(
            "The packages installed but could not be imported afterwards.\n\n"
            f"{_tail(transcript)}"
        )
    return transcript


def _tail(text: str, lines: int = 12) -> str:
    kept = [line for line in (text or "").splitlines() if line.strip()]
    return "\n".join(kept[-lines:])


# ------------------------------------------------------------- reading PDFs


def page_count(pdf: str | os.PathLike) -> int:
    tool = tool_path("pdfinfo")
    if tool is None:
        raise PaperError(
            "poppler is not installed, so the PDF cannot be read. "
            "Install it with: brew install poppler"
        )
    try:
        result = subprocess.run(
            [tool, str(pdf)], capture_output=True, text=True, timeout=120
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise PaperError(f"Could not inspect the PDF: {exc}") from None
    if result.returncode != 0:
        raise PaperError(f"Could not inspect the PDF: {_tail(result.stderr) or 'unreadable'}")
    for line in result.stdout.splitlines():
        if line.startswith("Pages:"):
            return int(line.split(":", 1)[1].strip())
    raise PaperError("That file does not look like a PDF.")


def progress_fraction(line: str) -> float | None:
    """Rendering and reading each count from 1 to n; the page reports both."""
    match = _PROGRESS.search(line or "")
    if match is None:
        return None
    stage, done, total = match.group(1), int(match.group(2)), int(match.group(3))
    if total <= 0:
        return None
    # Rendering is the first half of the work, reading the second.
    offset = 0.0 if stage == "Rendered" else 0.5
    return offset + (done / total) * 0.5


def contact_sheet(pdf, capture_dir=None, on_line=None) -> Path:
    """A thumbnail of every page, so the key page can be picked by eye."""
    out = Path(tempfile.mkdtemp(prefix="datalink-contact-"))
    command = [*pipeline_command(), str(pdf), "--list-pages", "--out", str(out)]
    code, transcript = _stream(command, on_line, timeout=RUN_TIMEOUT_SECONDS)
    sheet = out / "contact_sheet.png"
    if code != 0 or not sheet.is_file():
        shutil.rmtree(out, ignore_errors=True)
        raise PaperError(f"The page previews could not be rendered.\n\n{_tail(transcript)}")
    return sheet


def analyze(
    pdf,
    key_page: int,
    question_count: int = MAX_QUESTIONS,
    pages: str = "all",
    skip_pages: str = "",
    exam_name: str | None = None,
    capture_dir=None,
    on_line=None,
) -> dict:
    """Run the batch and return the pipeline's own analysis JSON."""
    pdf = Path(pdf).expanduser()
    if not pdf.is_file():
        raise PaperError(f"There is no file at {pdf}")
    if question_count not in range(1, MAX_QUESTIONS + 1):
        raise PaperError(
            f"The paper form holds {MAX_QUESTIONS} questions, so the count must "
            f"be from 1 to {MAX_QUESTIONS}."
        )
    cache = cache_root(capture_dir)
    cache.mkdir(parents=True, exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix="datalink-paper-"))
    command = [
        *pipeline_command(), str(pdf),
        "--key-page", str(int(key_page)),
        "--question-count", str(int(question_count)),
        "--pages", pages or "all",
        "--skip-pages", skip_pages or "",
        "--cache-dir", str(cache),
        "--out", str(out),
    ]
    if exam_name:
        command += ["--exam-name", exam_name]
    try:
        code, transcript = _stream(command, on_line, timeout=RUN_TIMEOUT_SECONDS)
        report_path = out / "analysis_result.json"
        if code != 0 or not report_path.is_file():
            raise PaperError(_pipeline_message(transcript))
        report = json.loads(report_path.read_text())
    finally:
        shutil.rmtree(out, ignore_errors=True)
    report["_log"] = transcript
    return report


def _pipeline_message(transcript: str) -> str:
    """The pipeline reports its own refusals on stdout, prefixed ERROR."""
    for line in reversed((transcript or "").splitlines()):
        if line.startswith("ERROR:"):
            return line[len("ERROR:") :].strip()
    return f"The sheets could not be read.\n\n{_tail(transcript)}"


# ------------------------------------------------- turning it into a session


def _responses(answers: list[dict], question_count: int) -> list[str]:
    """The pipeline's words for a mark, in the form the scans table stores.

    Blank is "", an unresolved erasure is "*" — exactly what a DataLink record
    carries, so analysis.normalize_response reads both the same way.
    """
    by_question = {int(entry.get("question") or 0): entry for entry in answers}
    values = []
    for question in range(1, question_count + 1):
        response = str((by_question.get(question) or {}).get("response") or "").upper()
        if response == "BLANK":
            values.append("")
        elif response == "MULTIPLE":
            values.append("*")
        else:
            values.append(response)
    return values


def session_from_report(store, report: dict, name: str = "", class_name: str = "") -> int:
    """Write a finished batch into the library as an ordinary session."""
    exam = report.get("exam") or {}
    question_count = int(exam.get("question_count") or MAX_QUESTIONS)
    students = list(report.get("students") or [])
    if not students:
        raise PaperError("No student sheets were read from that PDF.")

    key = [
        str(entry.get("answer") or "").upper()
        for entry in sorted(
            exam.get("answer_key") or [], key=lambda item: int(item.get("question") or 0)
        )
    ]
    if len(key) != question_count:
        raise PaperError("The answer key the pipeline read does not match the question count.")

    roster = _roster(store, class_name)
    created_at = str(report.get("created_at") or "")
    session_id = store.create_session(
        name or str(exam.get("name") or "Paper scan"),
        class_name,
        question_count,
        source="paper",
    )
    key_page = int(exam.get("key_page") or 1)
    store.add_scan(
        session_id,
        {
            "number": key_page,
            "role": "key",
            "student_id": None,
            "student_name": None,
            "received_at": created_at,
            "answered_count": sum(1 for value in key if value),
            "responses": key,
            "demo": False,
        },
    )
    for student in students:
        # student_id is None when the read was unsure; student_id_read keeps
        # what it saw, which is what the Review tab exists to correct.
        student_id = student.get("student_id") or student.get("student_id_read") or ""
        answers = student.get("answers") or []
        responses = _responses(answers, question_count)
        # How sure the reader was, kept per question. A mark barely above the
        # blank threshold is scored with full confidence by the pipeline, and
        # without this there is nothing left to notice that by.
        confidence = {
            str(entry.get("question")): entry.get("confidence")
            for entry in answers
            if entry.get("confidence")
        }
        store.add_scan(
            session_id,
            {
                "number": int(student.get("page") or 0),
                "role": "student",
                "student_id": str(student_id) or None,
                "student_name": student.get("student_name")
                or roster.get(str(student_id).strip()),
                "received_at": created_at,
                "answered_count": sum(1 for value in responses if value),
                "responses": responses,
                "demo": False,
                "confidence": confidence,
            },
        )
    return session_id


def _roster(store, class_name: str) -> dict[str, str]:
    """Student IDs to names, so a paper batch names its students too."""
    if not class_name:
        return {}
    entry = store.get_class(class_name)
    if entry is None:
        return {}
    return {
        str(student.get("id") or "").strip(): student.get("name") or ""
        for student in entry.get("students") or []
    }


# --------------------------------------------------------- work in progress


class Job:
    """One install or one batch, with progress the page can poll.

    Reading 40 pages takes minutes, so it cannot happen inside a request. One
    job runs at a time: two batches at once would fight over the same page
    cache and finish slower than running them in turn.
    """

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._thread: threading.Thread | None = None
        self.state = "idle"  # idle | installing | reading | done | failed
        self.progress = 0.0
        self.message = ""
        self.detail = ""
        self.session_id: int | None = None

    @property
    def busy(self) -> bool:
        return self.state in ("installing", "reading")

    def snapshot(self) -> dict:
        with self._lock:
            return {
                "state": self.state,
                "busy": self.busy,
                "progress": round(self.progress, 3),
                "message": self.message,
                "detail": self.detail,
                "session_id": self.session_id,
            }

    def _set(self, **values) -> None:
        with self._lock:
            for key, value in values.items():
                setattr(self, key, value)

    def start(self, state: str, message: str, work) -> None:
        """Run `work(report)` on a thread; `report` updates the progress."""
        if self.busy:
            raise PaperError("Something is already running; wait for it to finish.")
        self._set(
            state=state, progress=0.0, message=message, detail="", session_id=None
        )

        def report(progress: float | None = None, message: str | None = None) -> None:
            values = {}
            if progress is not None:
                values["progress"] = max(0.0, min(1.0, progress))
            if message is not None:
                values["message"] = message
            if values:
                self._set(**values)

        def run() -> None:
            try:
                result = work(report)
            except PaperError as exc:
                self._set(state="failed", message=str(exc))
            except Exception as exc:  # never leave the page waiting forever
                self._set(state="failed", message=str(exc))
            else:
                self._set(
                    state="done",
                    progress=1.0,
                    message=(result or {}).get("message", "Finished"),
                    session_id=(result or {}).get("session_id"),
                )

        self._thread = threading.Thread(target=run, daemon=True)
        self._thread.start()

    def reset(self) -> None:
        if not self.busy:
            self._set(state="idle", progress=0.0, message="", session_id=None)


# ----------------------------------------------------------------- storage


def directory_bytes(directory: Path) -> int:
    total = 0
    for root, _directories, files in os.walk(directory):
        for name in files:
            try:
                total += (Path(root) / name).stat().st_size
            except OSError:
                continue
    return total


def cache_report(capture_dir=None) -> dict:
    """What the paper pipeline is holding on disk."""
    cache = cache_root(capture_dir)
    support = support_dir()
    cache_bytes = directory_bytes(cache) if cache.is_dir() else 0
    batches = len([entry for entry in cache.glob("*") if entry.is_dir()]) if cache.is_dir() else 0
    return {
        "cache_dir": str(cache),
        "cache_bytes": cache_bytes,
        "batches": batches,
        "support_dir": str(support),
        "support_bytes": directory_bytes(support) if support.is_dir() else 0,
        "warn_bytes": CACHE_WARN_BYTES,
        "over_limit": cache_bytes >= CACHE_WARN_BYTES,
    }


def purge_cache(capture_dir=None) -> dict:
    """Delete the rendered pages. Scores and sessions are untouched.

    Only the page images go: everything the app shows about a batch is in the
    database by then, so the cost of this is re-rendering if a batch is run
    again, not losing a result.
    """
    cache = cache_root(capture_dir)
    freed = directory_bytes(cache) if cache.is_dir() else 0
    removed = 0
    if cache.is_dir():
        for entry in sorted(cache.iterdir()):
            try:
                if entry.is_dir():
                    shutil.rmtree(entry)
                else:
                    entry.unlink()
                removed += 1
            except OSError:
                continue
    return {"freed_bytes": freed, "removed": removed, **cache_report(capture_dir)}

"""Local-only HTTP workspace that the browser UI talks to.

The server binds to the loopback interface and never forwards scan data
anywhere. It owns a single :class:`ScannerController`, which holds the serial
connection and the reader thread.
"""

from __future__ import annotations

import csv
import errno
import io
import json
import mimetypes
import signal
import threading
import time
import webbrowser
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from . import __version__, paths
from . import edition
from . import paper
from . import ttess
from . import updates
from .analysis import (
    AnalysisError,
    analysis_filename,
    build_session_analysis,
    scan_fingerprint,
)
from .store import Store
from .interface import (
    DEFAULT_ANSWER_COUNT,
    MAX_ANSWER_COUNT,
    MIN_ANSWER_COUNT,
    DataLinkError,
    DataLinkFormRecord,
    DirectDataLinkScanner,
    append_jsonl,
    describe_message,
    discover_port,
    other_readers,
    validate_question_count,
)

# Python probes a list of system files the first time it guesses a MIME type.
# One of them, /etc/apache2/mime.types, exists on macOS but is unreadable
# inside the App Sandbox: os.path.isfile() says yes, open() raises
# PermissionError, and the exception escapes guess_type() and kills the
# request before a single byte reaches the browser. The window comes up blank
# with nothing logged.
#
# Emptying knownfiles is the only way to skip them: init(files=[]) does NOT
# replace that list, it appends to it, so passing an explicit list still reads
# every system file. Calling init() with no argument then builds the table from
# Python's own map alone, which also makes the types we serve identical on
# every machine regardless of what is installed in /etc.
mimetypes.knownfiles = []
mimetypes.init()


def safe_export_filename(test_name: str) -> str:
    cleaned = "".join(
        character
        if character.isascii() and (character.isalnum() or character in " ._-")
        else "_"
        for character in test_name.strip()
    ).strip(" .")
    cleaned = cleaned or "datalink-session"
    return cleaned if cleaned.lower().endswith(".csv") else f"{cleaned}.csv"


DESTINATIONS = ttess.DestinationCache()
ENDPOINT_SETTING = "ttess_api_url"
SITE_SETTING = "ttess_site_url"
PAPER_JOB = paper.Job()


def scored_session(store: Store, session_id: int) -> tuple[dict, dict]:
    """Score a session, reusing the run_id while its inputs are unchanged.

    A retry has to land on the same audit record; a re-score after a corrected
    ID or answer key has to be a new one.
    """
    session = store.session(session_id)
    if session is None:
        raise AnalysisError("No such session")
    # A roster imported or corrected after a batch was filed still names its
    # students. This runs before the fingerprint is taken, so the name is part
    # of what is hashed: a session uploaded before it had names and re-uploaded
    # after gets a new run_id, which is correct, because the payload did change.
    store.name_missing_students(session_id)
    scans = store.session_scans(session_id)
    fingerprint = scan_fingerprint(session, scans)
    run_id = session.get("analysis_run_id")
    if not run_id or session.get("analysis_fingerprint") != fingerprint:
        run_id = None
    report = build_session_analysis(
        session, scans, run_id=run_id, dismissed=store.dismissed_reviews(session_id)
    )
    if run_id != report["run_id"]:
        store.remember_run_id(session_id, report["run_id"], fingerprint)
    return session, report


def _install_paper_support(report) -> dict:
    """The install button's work: pip output is mostly noise, so only the
    lines that name a step are passed on."""
    def watch(line: str) -> None:
        if line.startswith(("Collecting", "Downloading", "Installing", "Successfully")):
            report(message=line[:90])

    paper.install_packages(on_line=watch)
    return {"message": f"Installed {', '.join(paper.PACKAGES)}"}


def _paper_run(store: Store, capture_root: Path, body: dict):
    """Read a PDF batch and file the result as a session."""
    pdf = str(body.get("path", ""))
    key_page = int(body.get("key_page", 0) or 0)
    question_count = int(body.get("question_count", paper.MAX_QUESTIONS) or 0)
    pages = str(body.get("pages", "all") or "all")
    skip_pages = str(body.get("skip_pages", "") or "")
    name = str(body.get("name", "") or "")
    class_name = str(body.get("class_name", "") or "")
    # Answers the teacher supplied for key questions the reader could not
    # settle on its own. The reader takes them as --key-overrides.
    key_overrides = {
        str(question): str(answer).upper()
        for question, answer in dict(body.get("key_overrides") or {}).items()
        if str(answer).upper() in {"A", "B", "C", "D", "E"}
    }

    def work(report) -> dict:
        if key_page < 1:
            raise paper.PaperError("Choose which page holds the answer key.")

        def watch(line: str) -> None:
            fraction = paper.progress_fraction(line)
            if fraction is not None:
                report(
                    progress=fraction,
                    message=("Rendering the pages…" if fraction < 0.5 else "Reading the sheets…"),
                )

        result = paper.analyze(
            pdf,
            key_page=key_page,
            question_count=question_count,
            pages=pages,
            skip_pages=skip_pages,
            exam_name=name or None,
            capture_dir=capture_root,
            on_line=watch,
            key_overrides=key_overrides or None,
        )
        report(progress=0.98, message="Filing the results…")
        session_id = paper.session_from_report(store, result, name=name, class_name=class_name)
        students = len(result.get("students") or [])
        return {
            "session_id": session_id,
            "message": f"Read {students} sheet{'' if students == 1 else 's'}",
        }

    return work


def records_to_csv(
    records: list[dict[str, object]], class_name: str, fallback_columns: int
) -> bytes:
    """One CSV shape for both a live session and one replayed from history."""
    output = io.StringIO()
    writer = csv.writer(output)
    maximum = max(
        (len(record["responses"]) for record in records), default=fallback_columns
    )
    writer.writerow(
        ["Scan", "Role", "Class", "Student ID", "Student Name", "Received At", "Answered"]
        + [f"Q{index}" for index in range(1, maximum + 1)]
    )
    for record in records:
        writer.writerow(
            [
                record["number"],
                record.get("role", "student"),
                class_name,
                record.get("student_id") or "",
                record.get("student_name") or "",
                record["received_at"],
                record["answered_count"],
            ]
            + list(record["responses"])
        )
    return output.getvalue().encode("utf-8")


class ScannerController:
    def __init__(self, capture_root: Path, store: Store) -> None:
        self.capture_root = capture_root
        self.store = store
        self._session_id: int | None = None
        self._lock = threading.RLock()
        self._scanner: DirectDataLinkScanner | None = None
        self._reader: threading.Thread | None = None
        self._stop = threading.Event()
        self._records: list[dict[str, object]] = []
        self._pending_reviews: list[dict[str, object]] = []
        self._pending_record_objects: dict[int, DataLinkFormRecord] = {}
        self._activity: list[dict[str, str]] = []
        self._state = "disconnected"
        self._port: str | None = None
        self._error: str | None = None
        self._output_path: Path | None = None
        self._question_count = DEFAULT_ANSWER_COUNT
        self._session_name = ""
        # Held while the handshake is re-sent, so the reader thread and
        # transact() are never reading the same port at the same time.
        self._paused = threading.Event()
        self._idle = threading.Event()
        self._idle.set()

    def snapshot(self) -> dict[str, object]:
        with self._lock:
            return {
                "state": self._state,
                "port": self._port,
                "error": self._error,
                "record_count": len(self._records),
                "records": list(self._records),
                "pending_review": dict(self._pending_reviews[0]) if self._pending_reviews else None,
                "activity": list(self._activity[:30]),
                "output_path": str(self._output_path) if self._output_path else None,
                "capture_root": str(self.capture_root),
                "session_id": self._session_id,
                "session_name": self._session_name,
                "scanning": self._session_id is not None,
                "question_count": self._question_count,
                "min_question_count": MIN_ANSWER_COUNT,
                "max_question_count": MAX_ANSWER_COUNT,
            }

    def _log(self, message: str, kind: str = "info") -> None:
        with self._lock:
            self._activity.insert(
                0,
                {
                    "time": datetime.now().astimezone().strftime("%H:%M:%S"),
                    "message": message,
                    "kind": kind,
                },
            )
        print(f"[{kind.upper()}] {message}", flush=True)

    def available_ports(self) -> list[str]:
        import glob

        return sorted(set(glob.glob("/dev/cu.usbserial*") + glob.glob("/dev/tty.usbserial*")))

    def connect(self, requested_port: str | None, question_count: int) -> None:
        """Open the port and run the handshake. This starts no session.

        Connecting and scanning used to be the same act, which left no way to
        finish one class's sheets and begin the next without unplugging. The
        hardware is now brought up once and a session is started and ended on
        top of it as often as the day needs.
        """
        question_count = validate_question_count(question_count)
        with self._lock:
            if self._state in {"connecting", "connected"}:
                raise DataLinkError("Scanner is already connected or connecting")
            self._state = "connecting"
            self._error = None
        self._log("Opening the scanner and running the captured handshake.")

        scanner: DirectDataLinkScanner | None = None
        try:
            port = requested_port or discover_port()
            # Two readers on one port take each other's bytes and neither is
            # told. Saying so beats losing a character in the middle of a
            # sheet, which is what happened before this check existed.
            competing = other_readers(port)
            if competing:
                raise DataLinkError(
                    f"{' and '.join(competing)} already has the scanner open. "
                    "Close it first — two programs reading the same port lose "
                    "characters from each other."
                )
            scanner = DirectDataLinkScanner(port, question_count=question_count)
            scanner.open()
            initialization = scanner.initialize()
            transition = scanner.enter_data_collection()
            with self._lock:
                self._scanner = scanner
                self._port = port
                self._question_count = question_count
                self._state = "connected"
                self._stop.clear()
                self._paused.clear()
            for command, reply in initialization + transition:
                self._log(f"{command} → {reply}", "protocol")
            self._log("Data Collection is active.", "success")
            self._reader = threading.Thread(target=self._read_loop, daemon=True)
            self._reader.start()
        except Exception as exc:
            if scanner is not None:
                scanner.close()
            with self._lock:
                self._state = "error"
                self._error = str(exc)
                self._scanner = None
                self._port = requested_port
            self._log(str(exc), "error")
            raise

    def start_session(
        self,
        question_count: int | None = None,
        *,
        reset_scanner: bool = False,
    ) -> int:
        """Open a session with a fresh scanner collection state.

        The explicit UI action resets a connected scanner first. A DataLink
        can retain a pending second-side prompt after an interrupted key; the
        reset clears that state before the next one-sided key is fed. The
        reader's automatic-session path leaves the port alone because a sheet
        has already arrived by then.
        """
        if reset_scanner:
            with self._lock:
                connected = self._scanner is not None
            if connected:
                self.reset_scanner()
        with self._lock:
            if self._session_id is not None:
                raise DataLinkError(
                    "A session is already running. End it before starting another."
                )
            if question_count is not None:
                self._question_count = validate_question_count(question_count)
            count = self._question_count
            if self._scanner is not None:
                self._scanner.parser.question_count = count

            name = self.store.get_setting("test_name")
            class_name = self.store.get_setting("selected_class")
            stamp = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
            self.capture_root.mkdir(parents=True, exist_ok=True)
            output_path = self.capture_root / f"browser_session_{stamp}.jsonl"
            session_id = self.store.create_session(
                name, class_name, count, log_path=str(output_path)
            )
            self._session_id = session_id
            self._session_name = name
            self._output_path = output_path
            self._records.clear()
            self._pending_reviews.clear()
            self._pending_record_objects.clear()
        label = f"“{name}”" if name else "an unnamed session"
        self._log(f"Started {label}. Feed the answer key first.", "success")
        return session_id

    def end_session(self) -> dict[str, object]:
        """Close the session and leave the scanner up for the next one."""
        with self._lock:
            session_id = self._session_id
            if session_id is None:
                raise DataLinkError("No session is running")
            saved = self.store.session_scans(session_id)
            sheets = len(saved)
            keys = sum(1 for record in saved if record.get("role") == "key")
            waiting = len(self._pending_reviews)
            name = self._session_name
            self._session_id = None
            self._session_name = ""
            self._output_path = None
            self._pending_reviews.clear()
            self._pending_record_objects.clear()

        self.store.update_session(session_id, finished=True)
        self.store.prune_empty_sessions(session_id)
        students = max(sheets - keys, 0)
        label = f"“{name}”" if name else "The session"
        summary = (
            f"{label} ended with {students} student sheet"
            f"{'' if students == 1 else 's'}"
            + (" and no answer key." if not keys else ".")
        )
        if waiting:
            summary += (
                f" {waiting} sheet{'' if waiting == 1 else 's'}"
                f" {'was' if waiting == 1 else 'were'} still waiting for review"
                "; all remain saved for review under Analysis."
            )
        self._log(summary, "warning" if waiting or not keys else "success")
        return {
            "session_id": session_id,
            "sheets": students,
            "discarded": 0,
            "pending_review": waiting,
            "message": summary,
        }

    def reset_scanner(self) -> None:
        """Re-send the handshake on the open port.

        This was written believing it was the software equivalent of the
        Reset button on the device. It is not, and measurement said so: with
        the handshake already in force a sheet was still held for its other
        side, and only a press of the physical button cleared it. The mode is
        chosen at the device and nothing in the captured command set changes
        it. What this does do is re-establish Data Collection when the
        conversation itself has got out of step.
        """
        with self._lock:
            scanner = self._scanner
        if scanner is None:
            raise DataLinkError("Connect the scanner first")

        self._paused.set()
        # Let the reader finish whatever read it is inside before touching the
        # port; two readers on one serial port lose bytes between them.
        self._idle.wait(timeout=2.0)
        try:
            transcript = scanner.resynchronize()
        except Exception as exc:
            self._log(f"Could not reset the scanner: {exc}", "error")
            raise
        finally:
            self._paused.clear()
        for command, reply in transcript:
            self._log(f"{command} → {reply}", "protocol")
        self._log(
            "Re-sent the handshake and Data Collection is active again. This "
            "does not change the mode the scanner is in: if it is holding a "
            "sheet and asking for its other side, press Reset on the device "
            "until its display reads Scan Mode Ready.",
            "success",
        )

    def _read_loop(self) -> None:
        while not self._stop.is_set():
            if self._paused.is_set():
                # reset_scanner() owns the port until it clears this.
                self._idle.set()
                time.sleep(0.02)
                continue
            self._idle.clear()
            with self._lock:
                scanner = self._scanner
            if scanner is None:
                self._idle.set()
                return
            try:
                with self._lock:
                    records, messages = scanner.read_available()
                    fragment = scanner.parser.take_stale_fragment()
                    if fragment is not None:
                        messages.append(fragment)
                    for message in messages:
                        # A line that is not a form record used to be filed as
                        # protocol chatter, which the activity list hides unless
                        # protocol details are showing. That is precisely how a
                        # scanner asking for the other side of a sheet went unread
                        # while nothing else would feed.
                        kind, described = describe_message(message)
                        self._log(described, kind)
                    if records and self._session_id is None:
                        # A sheet has already gone through the machine. Refusing it
                        # here would lose it for good, so open a session around it
                        # and say so.
                        self.start_session()
                        self._log(
                            "A sheet arrived with no session running, so one was "
                            "started for it.",
                            "warning",
                        )
                    with self._lock:
                        output_path = self._output_path
                    for record in records:
                        public = record.public_dict(include_raw_fields=False)
                        with self._lock:
                            public["number"] = len(self._records) + len(self._pending_reviews) + 1
                            public["role"] = "key" if public["number"] == 1 else "student"
                            ambiguities = [
                                {
                                    "question": index + 1,
                                    "value": value,
                                    "options": list(value),
                                }
                                for index, value in enumerate(record.responses)
                                if len(value) > 1
                            ]
                            if public["role"] == "student" or ambiguities:
                                public["student_id"] = public.get("scanner_id")
                                public["pending_review"] = True
                                # Save before presenting the sheet to the UI. The stored
                                # pending flag keeps it reviewable after a restart.
                                self.store.add_scan(self._session_id, public)
                                if output_path is not None:
                                    append_jsonl(output_path, record, False, extra=public)
                                review = {
                                    "id": public["number"],
                                    "number": public["number"],
                                    "role": public["role"],
                                    "received_at": public["received_at"],
                                    "ambiguities": ambiguities,
                                    "student_id_required": public["role"] == "student",
                                    "scanner_id": public.get("scanner_id"),
                                }
                                self._pending_reviews.append(review)
                                self._pending_record_objects[public["number"]] = record
                                if ambiguities:
                                    detail = ", ".join(
                                        f"question {item['question']}" for item in ambiguities
                                    )
                                    self._log(
                                        f"Sheet {public['number']} needs review for {detail}.",
                                        "warning",
                                    )
                                else:
                                    if public.get("scanner_id"):
                                        self._log(
                                            f"Scanner read student ID {public['scanner_id']} from sheet {public['number'] - 1}.",
                                            "success",
                                        )
                                    else:
                                        self._log(
                                            f"Student sheet {public['number'] - 1} is waiting for its student ID.",
                                            "warning",
                                        )
                                continue
                            self._records.append(public)
                        if output_path is not None:
                            append_jsonl(
                                output_path,
                                record,
                                include_raw_fields=False,
                                extra={"number": public["number"], "role": public["role"]},
                            )
                        self._record_scan(public)
                        self._log(
                            (
                                f"Captured answer key with {public['answered_count']}/{len(record.responses)} answered."
                                if public["role"] == "key"
                                else f"Captured student sheet {public['number'] - 1} with "
                                f"{public['answered_count']}/{len(record.responses)} answered."
                            ),
                            "success",
                        )
            except DataLinkError as exc:
                self._log(f"Skipped an invalid scanner record: {exc}", "error")
                continue
            except Exception as exc:
                with self._lock:
                    self._state = "error"
                    self._error = str(exc)
                self._log(f"Scanner read failed: {exc}", "error")
                self._idle.set()
                return
            finally:
                self._idle.set()
            time.sleep(0.025)

    def resolve_review(
        self,
        review_id: int,
        resolutions: dict[str, str],
        student_id: str,
        student_name: str,
    ) -> None:
        with self._lock:
            review = next(
                (item for item in self._pending_reviews if item["id"] == review_id),
                None,
            )
            record = self._pending_record_objects.get(review_id)
            if review is None or record is None:
                raise DataLinkError("That review is no longer pending")

            corrected = list(record.responses)
            student_id = student_id.strip()
            student_name = student_name.strip()
            if review["role"] == "student" and not student_id:
                raise DataLinkError("Enter the student ID")
            if student_id and not student_id.isdigit():
                raise DataLinkError("Student ID must contain digits only")
            for ambiguity in review["ambiguities"]:
                question = int(ambiguity["question"])
                selected = resolutions.get(str(question))
                allowed = set(ambiguity["options"]) | {"", ambiguity["value"]}
                if selected not in allowed:
                    raise DataLinkError(f"Choose a resolution for question {question}")
                corrected[question - 1] = selected

            public = {
                "number": review["number"],
                "role": review["role"],
                "received_at": record.received_at,
                "responses": corrected,
                "answered_count": sum(bool(value) for value in corrected),
                "student_id": student_id or None,
                "student_name": student_name or None,
                # Carried through the review, or the machine's own marking
                # would be lost on every sheet that needed one — which is
                # every student sheet.
                "scanner_score": record.public_dict().get("scanner_score"),
            }
            self.store.update_scan(self._session_id, int(public["number"]),
                                   student_id=student_id, student_name=student_name,
                                   responses=corrected)
            self._records.append(public)
            self._records.sort(key=lambda item: int(item["number"]))
            self._pending_reviews.remove(review)
            del self._pending_record_objects[review_id]
            output_path = self._output_path

        corrected_record = DataLinkFormRecord(record.received_at, record.fields, corrected)
        if output_path is not None:
            append_jsonl(
                output_path,
                corrected_record,
                include_raw_fields=False,
                extra={
                    "number": public["number"],
                    "role": public["role"],
                    "student_id": public["student_id"],
                    "student_name": public["student_name"],
                },
            )
        label = "answer key" if public["role"] == "key" else f"student sheet {int(public['number']) - 1}"
        self._log(f"Saved reviewed {label}.", "success")

    def _record_scan(self, public: dict[str, object]) -> None:
        with self._lock:
            session_id = self._session_id
        if session_id is None:
            return
        try:
            self.store.add_scan(session_id, public)
        except Exception as exc:
            # A history write must never cost a sheet that is already in the
            # JSONL log and on screen.
            self._log(f"Could not save sheet {public.get('number')} to history: {exc}", "error")

    def disconnect(self) -> None:
        if self._session_id is not None:
            # Unplugging still ends the session, and says so the same way the
            # End session button does.
            try:
                self.end_session()
            except DataLinkError:
                pass
        self._stop.set()
        self._paused.clear()
        with self._lock:
            scanner = self._scanner
            self._scanner = None
            self._session_id = None
            self._session_name = ""
            self._output_path = None
            self._state = "disconnected"
            self._port = None
            self._error = None
        if scanner is not None:
            scanner.close()
        self._log("Scanner disconnected.")

    def remove_sessions(self, session_ids: list[int]) -> dict[str, int]:
        """Delete sessions, their scans and their JSONL logs together."""
        doomed = []
        for session_id in session_ids:
            session = self.store.session(session_id)
            if session and session.get("log_path"):
                doomed.append(Path(session["log_path"]))
        removed = self.store.delete_sessions(session_ids)
        logs = 0
        for path in doomed:
            try:
                path.unlink()
                logs += 1
            except OSError:
                # A log the user has already moved or deleted is not an error.
                pass
        if removed:
            self.store.vacuum()
        return {"sessions": removed, "logs": logs}

    def current_session_id(self) -> int | None:
        with self._lock:
            return self._session_id

    def clear(self) -> None:
        with self._lock:
            if self._session_id is not None:
                # Sheets are numbered from what is on screen, and sheet 1 is
                # the answer key. Emptying the table mid-session sent the next
                # sheet in as a second key on a number already used, and the
                # session could never be scored again.
                raise DataLinkError(
                    "A session is running, so the sheets on screen are the ones "
                    "being recorded. End the session to start a fresh one."
                )
            self._records.clear()
            self._pending_reviews.clear()
            self._pending_record_objects.clear()
        self._log("The on-screen session was cleared.")

    def export_csv(self, class_name: str = "") -> bytes:
        with self._lock:
            records = list(self._records)
            fallback = self._question_count
        return records_to_csv(records, class_name, fallback)



class DataLinkRequestHandler(SimpleHTTPRequestHandler):
    controller: ScannerController
    shutdown_requested: threading.Event

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(paths.web_root()), **kwargs)

    def log_message(self, format: str, *args) -> None:
        return

    def _save_endpoint(self, url: str) -> None:
        """Remember where this copy uploads to, and start using it now.

        Refused unless it is https: the token travels on this request as a
        bearer header, and student data travels in the body.
        """
        url = url.strip()
        if url:
            ttess._require_https(url)
        self.store.set_setting(ENDPOINT_SETTING, url)
        ttess.set_endpoint(url)

    def _save_site(self, url: str) -> None:
        """Where the teacher reads the reports, for the link in Settings."""
        url = url.strip()
        if url:
            ttess._require_https(url)
        self.store.set_setting(SITE_SETTING, url)
        ttess.set_site(url)

    def end_headers(self) -> None:
        self.send_header("Cache-Control", "no-store, max-age=0")
        super().end_headers()

    def _json_body(self) -> dict[str, object]:
        length = int(self.headers.get("Content-Length", "0"))
        if length == 0:
            return {}
        return json.loads(self.rfile.read(length).decode("utf-8"))

    def _send_json(self, payload: object, status: int = HTTPStatus.OK) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    @property
    def store(self) -> Store:
        return self.controller.store

    def _session_id_from(self, path: str, suffix: str = "") -> int | None:
        prefix = "/api/sessions/"
        if not path.startswith(prefix):
            return None
        remainder = path[len(prefix) :]
        if suffix:
            if not remainder.endswith(suffix):
                return None
            remainder = remainder[: -len(suffix)]
        return int(remainder) if remainder.isdigit() else None

    def _send_csv(self, body: bytes, filename: str) -> None:
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/csv; charset=utf-8")
        self.send_header("Content-Disposition", f'attachment; filename="{filename}"')
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/api/classes":
            self._send_json({"classes": self.store.list_classes()})
            return
        if path == "/api/settings":
            checked = updates.last_checked(self.store)
            self._send_json(
                {
                    "test_name": self.store.get_setting("test_name"),
                    "selected_class": self.store.get_setting("selected_class"),
                    "question_count": self.store.get_setting("question_count"),
                    "student_matching": self.store.get_setting(
                        "student_matching", "id"
                    ),
                    "auto_update_check": updates.auto_check_enabled(self.store),
                    # The page hides the things this edition may not do.
                    "sandboxed": edition.sandboxed(),
                    "last_update_check": (
                        datetime.fromtimestamp(checked).isoformat() if checked else None
                    ),
                    "app_version": __version__,
                }
            )
            return
        if path == "/api/sessions":
            self._send_json({"sessions": self.store.list_sessions()})
            return
        if path == "/api/connection":
            bearer = ttess.token()
            payload = {
                "connected": bool(bearer),
                "api_url": ttess.api_url(),
                "site_url": ttess.site_url(),
                # The store edition has no address of its own and shows the
                # field instead of a link to somebody else's site.
                "sandboxed": edition.sandboxed(),
                "destinations": [],
                "error": None,
            }
            if bearer:
                try:
                    payload["destinations"] = DESTINATIONS.get(bearer)
                except ttess.UploadError as exc:
                    payload["error"] = str(exc)
                    payload["connected"] = bool(ttess.token())
            self._send_json(payload)
            return
        if path == "/api/destinations":
            try:
                self._send_json(
                    {"destinations": DESTINATIONS.get(force=True), "error": None}
                )
            except ttess.UploadError as exc:
                self._send_json({"error": str(exc)}, HTTPStatus.BAD_REQUEST)
            return
        if path == "/api/storage":
            report = self.store.storage_report()
            report["paper"] = paper.cache_report(self.controller.capture_root)
            self._send_json(report)
            return
        if path == "/api/paper":
            # The status probe starts an interpreter, so it is not run on the
            # progress poll — only when the page asks for the whole picture.
            self._send_json(
                {
                    "support": paper.status(),
                    "storage": paper.cache_report(self.controller.capture_root),
                    "job": PAPER_JOB.snapshot(),
                    "max_questions": paper.MAX_QUESTIONS,
                }
            )
            return
        if path == "/api/paper/job":
            self._send_json(
                {
                    "job": PAPER_JOB.snapshot(),
                    "storage": paper.cache_report(self.controller.capture_root),
                }
            )
            return
        # Same report, served inline for the Analysis page rather than as a
        # download.
        session_id = self._session_id_from(path, "/analysis")
        if session_id is not None:
            session = self.store.session(session_id)
            if session is None:
                self._send_json({"error": "No such session"}, HTTPStatus.NOT_FOUND)
                return
            try:
                report = scored_session(self.store, session_id)[1]
            except AnalysisError as exc:
                self._send_json({"error": str(exc)}, HTTPStatus.BAD_REQUEST)
                return
            # Only on the inline report the Review tab reads. The downloadable
            # one and the T-TESS upload keep the schema the site expects.
            cache = session.get("page_cache")
            report["has_pages"] = bool(cache) and Path(cache).is_dir()
            # Which roster this test was scanned against, so a corrected ID can
            # pull the right name. The session's class, not whichever one the
            # Scan tab happens to have selected now.
            report["class_name"] = session.get("class_name") or ""
            report["dismissed_count"] = len(self.store.dismissed_reviews(session_id))
            self._send_json(report)
            return
        session_id = self._session_id_from(path, "/analysis.json")
        if session_id is not None:
            session = self.store.session(session_id)
            if session is None:
                self._send_json({"error": "No such session"}, HTTPStatus.NOT_FOUND)
                return
            try:
                report = scored_session(self.store, session_id)[1]
            except AnalysisError as exc:
                self._send_json({"error": str(exc)}, HTTPStatus.BAD_REQUEST)
                return
            body = json.dumps(report, indent=2).encode("utf-8")
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header(
                "Content-Disposition",
                f'attachment; filename="{analysis_filename(session)}"',
            )
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        session_id = self._session_id_from(path, "/export.csv")
        if session_id is not None:
            session = self.store.session(session_id)
            if session is None:
                self._send_json({"error": "No such session"}, HTTPStatus.NOT_FOUND)
                return
            self.store.name_missing_students(session_id)
            body = records_to_csv(
                self.store.session_scans(session_id),
                session["class_name"],
                session["question_count"],
            )
            self._send_csv(body, safe_export_filename(session["name"]))
            return
        session_id = self._session_id_from(path)
        if session_id is not None:
            session = self.store.session(session_id)
            if session is None:
                self._send_json({"error": "No such session"}, HTTPStatus.NOT_FOUND)
                return
            self.store.name_missing_students(session_id)
            scans = self.store.session_scans(session_id)
            session["scans"] = scans
            # The browser only needs to know whether a sheet can be looked at,
            # not where on disk it lives.
            cache = session.pop("page_cache", None)
            session["has_pages"] = bool(cache) and Path(cache).is_dir()
            try:
                build_session_analysis(
                    session, scans,
                    dismissed=self.store.dismissed_reviews(session_id),
                )
                session["analysis_available"] = True
                session["analysis_error"] = None
            except AnalysisError as exc:
                session["analysis_available"] = False
                session["analysis_error"] = str(exc)
            self._send_json(session)
            return
        if path.startswith("/api/sessions/") and "/page/" in path:
            # /api/sessions/<id>/page/<n> — the sheet as it was scanned, for
            # reading a name off the paper while correcting it.
            head, _, tail = path.partition("/page/")
            session_id = self._session_id_from(head)
            session = self.store.session(session_id) if session_id else None
            if session is None:
                self._send_json({"error": "No such session"}, HTTPStatus.NOT_FOUND)
                return
            page = tail.split(".")[0]
            if not page.isdigit():
                self._send_json({"error": "Not found"}, HTTPStatus.NOT_FOUND)
                return
            try:
                body, content_type = paper.page_image(
                    session.get("page_cache"), int(page)
                )
            except paper.PaperError as exc:
                self._send_json({"error": str(exc)}, HTTPStatus.NOT_FOUND)
                return
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if path == "/api/paper/page":
            # One rendered page of a batch, by the cache the reader filled.
            # There is no session yet — the run stopped on the answer key —
            # so this goes by the PDF rather than by a session id.
            query = parse_qs(parsed.query)
            pdf = query.get("path", [""])[0]
            page = query.get("page", [""])[0]
            if not pdf or not page.isdigit():
                self._send_json({"error": "Not found"}, HTTPStatus.NOT_FOUND)
                return
            try:
                body, content_type = paper.page_image(
                    paper.page_cache_dir(pdf, self.controller.capture_root), int(page)
                )
            except (paper.PaperError, OSError) as exc:
                self._send_json({"error": str(exc)}, HTTPStatus.NOT_FOUND)
                return
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if path == "/api/status":
            snapshot = self.controller.snapshot()
            snapshot["ports"] = self.controller.available_ports()
            self._send_json(snapshot)
            return
        if path == "/api/export.csv":
            query = parse_qs(parsed.query)
            class_name = query.get("class", [""])[0]
            body = self.controller.export_csv(class_name)
            self._send_csv(body, safe_export_filename(query.get("name", [""])[0]))
            return
        super().do_GET()

    def do_POST(self) -> None:
        path = urlparse(self.path).path
        try:
            body = self._json_body()
            if path == "/api/connect":
                if body.get("acknowledge_writes") is not True:
                    raise DataLinkError("Scanner command acknowledgement is required")
                self.controller.connect(
                    body.get("port") or None,
                    body.get("question_count", DEFAULT_ANSWER_COUNT),
                )
            elif path == "/api/session/start":
                self.controller.start_session(
                    body.get("question_count") or None,
                    reset_scanner=True,
                )
            elif path == "/api/session/end":
                summary = self.controller.end_session()
                snapshot = self.controller.snapshot()
                snapshot["ports"] = self.controller.available_ports()
                snapshot["summary"] = summary
                self._send_json(snapshot)
                return
            elif path == "/api/scanner/reset":
                self.controller.reset_scanner()
            elif path == "/api/disconnect":
                self.controller.disconnect()
            elif path == "/api/clear":
                self.controller.clear()
            elif path == "/api/quit":
                self.controller.disconnect()
                self._send_json({"stopping": True})
                self.shutdown_requested.set()
                return
            elif path == "/api/classes/save":
                self.store.save_class(
                    str(body.get("name", "")),
                    list(body.get("students", [])),
                    body.get("original_name") or None,
                )
                self._send_json({"classes": self.store.list_classes()})
                return
            elif path == "/api/classes/delete":
                name = str(body.get("name", ""))
                self.store.delete_class(name)
                if self.store.get_setting("selected_class") == name:
                    self.store.set_setting("selected_class", "")
                self._send_json({"classes": self.store.list_classes()})
                return
            elif path == "/api/classes/import":
                imported = self.store.import_classes(list(body.get("classes", [])))
                self._send_json(
                    {"imported": imported, "classes": self.store.list_classes()}
                )
                return
            elif path == "/api/settings":
                for key in (
                    "test_name", "selected_class", "question_count",
                    "student_matching",
                ):
                    if key in body:
                        self.store.set_setting(key, str(body[key]))
                if "auto_update_check" in body:
                    updates.set_auto_check(self.store, bool(body["auto_update_check"]))
                if "ttess_api_url" in body:
                    self._save_endpoint(str(body["ttess_api_url"]))
                if "ttess_site_url" in body:
                    self._save_site(str(body["ttess_site_url"]))
                # Keep an open history row in step with a renamed test or class.
                session_id = self.controller.current_session_id()
                if session_id is not None:
                    self.store.update_session(
                        session_id,
                        name=str(body["test_name"]) if "test_name" in body else None,
                        class_name=(
                            str(body["selected_class"]) if "selected_class" in body else None
                        ),
                    )
                self._send_json({"ok": True})
                return
            elif path == "/api/paper/install":
                try:
                    PAPER_JOB.start(
                        "installing",
                        "Downloading about 51 MB…",
                        lambda report: _install_paper_support(report),
                    )
                except paper.PaperError as exc:
                    self._send_json({"error": str(exc)}, HTTPStatus.CONFLICT)
                    return
                self._send_json({"job": PAPER_JOB.snapshot()})
                return
            elif path == "/api/paper/pages":
                try:
                    count = paper.page_count(str(body.get("path", "")))
                except paper.PaperError as exc:
                    self._send_json({"error": str(exc)}, HTTPStatus.BAD_REQUEST)
                    return
                self._send_json({"pages": count})
                return
            elif path == "/api/paper/run":
                try:
                    PAPER_JOB.start(
                        "reading",
                        "Rendering the pages…",
                        _paper_run(self.store, self.controller.capture_root, body),
                    )
                except paper.PaperError as exc:
                    self._send_json({"error": str(exc)}, HTTPStatus.CONFLICT)
                    return
                self._send_json({"job": PAPER_JOB.snapshot()})
                return
            elif path == "/api/paper/purge":
                result = paper.purge_cache(self.controller.capture_root)
                self._send_json(result)
                return
            elif path == "/api/paper/dismiss":
                PAPER_JOB.reset()
                self._send_json({"job": PAPER_JOB.snapshot()})
                return
            elif path == "/api/sessions/review/dismiss":
                session_id = int(body.get("session_id", 0))
                if self.store.session(session_id) is None:
                    self._send_json({"error": "No such session"}, HTTPStatus.NOT_FOUND)
                    return
                added = self.store.dismiss_reviews(
                    session_id, list(body.get("items", []))
                )
                self._send_json({"dismissed": added})
                return
            elif path == "/api/sessions/review/restore":
                session_id = int(body.get("session_id", 0))
                if self.store.session(session_id) is None:
                    self._send_json({"error": "No such session"}, HTTPStatus.NOT_FOUND)
                    return
                self._send_json({"restored": self.store.restore_reviews(session_id)})
                return
            elif path == "/api/sessions/correct":
                session_id = int(body.get("session_id", 0))
                session = self.store.session(session_id)
                if session is None:
                    self._send_json({"error": "No such session"}, HTTPStatus.NOT_FOUND)
                    return
                corrections = list(body.get("corrections", []))
                dismiss = list(body.get("dismiss", []))
                if not corrections and not dismiss:
                    raise DataLinkError("No corrections were supplied")
                validated = []
                for correction in corrections:
                    number = int(correction.get("number", 0))
                    responses = correction.get("responses")
                    if responses is not None:
                        responses = [str(value).strip().upper() for value in responses]
                        responses = [
                            {"BLANK": "", "MULTIPLE": "*"}.get(value, value)
                            for value in responses
                        ]
                        expected = int(session["question_count"])
                        if len(responses) != expected:
                            raise DataLinkError(
                                f"Sheet {number} needs exactly {expected} responses"
                            )
                        for value in responses:
                            if value and value != "*" and not all(
                                letter in "ABCDE" for letter in value
                            ):
                                raise DataLinkError(
                                    f"{value!r} is not a valid response"
                                )
                    student_id = correction.get("student_id")
                    if student_id is not None:
                        student_id = str(student_id).strip()
                        if student_id and not student_id.isdigit():
                            raise DataLinkError("Student ID must contain digits only")
                    name = correction.get("student_name")
                    validated.append(dict(number=number, student_id=student_id,
                                          student_name=None if name is None else str(name).strip(),
                                          responses=responses))
                applied, settled = self.store.apply_corrections(session_id, validated, dismiss)
                # A corrected ID may be one the roster can name.
                self.store.name_missing_students(session_id)
                scans = self.store.session_scans(session_id)
                payload = {"applied": applied, "dismissed": settled}
                try:
                    payload["analysis"] = build_session_analysis(
                        session, scans,
                        dismissed=self.store.dismissed_reviews(session_id),
                    )
                except AnalysisError as exc:
                    payload["analysis"] = None
                    payload["analysis_error"] = str(exc)
                self._send_json(payload)
                return
            elif path == "/api/connection/connect":
                # The token itself is never echoed back, logged or stored
                # anywhere but the Keychain.
                try:
                    ttess.save_token(str(body.get("token", "")))
                    destinations = DESTINATIONS.refresh()
                except ttess.UploadError as exc:
                    if exc.code != "invalid_token":
                        ttess.forget_token()
                    self._send_json(
                        {"error": str(exc), "code": exc.code}, HTTPStatus.BAD_REQUEST
                    )
                    return
                self._send_json({"connected": True, "destinations": destinations})
                return
            elif path == "/api/connection/disconnect":
                ttess.forget_token()
                DESTINATIONS.destinations = []
                DESTINATIONS.fetched_at = 0.0
                self._send_json({"connected": False, "destinations": []})
                return
            elif path == "/api/sessions/upload":
                session_id = int(body.get("session_id", 0))
                try:
                    session, report = scored_session(self.store, session_id)
                except AnalysisError as exc:
                    self._send_json({"error": str(exc)}, HTTPStatus.BAD_REQUEST)
                    return
                exam_id = str(body.get("exam_id", ""))
                destination = next(
                    (
                        item
                        for item in DESTINATIONS.get()
                        if item.get("exam_id") == exam_id
                    ),
                    None,
                )
                if destination is None:
                    # Stale pick, or the teacher lost access to that test.
                    destination = next(
                        (
                            item
                            for item in DESTINATIONS.get(force=True)
                            if item.get("exam_id") == exam_id
                        ),
                        None,
                    )
                if destination is None:
                    self._send_json(
                        {
                            "error": "That test is no longer available. Choose "
                            "another destination.",
                            "code": "exam_forbidden",
                        },
                        HTTPStatus.BAD_REQUEST,
                    )
                    return
                try:
                    result = ttess.upload(
                        exam_id,
                        report,
                        str(destination.get("test_code", "")),
                        replace_run_id=(
                            str(body.get("replace_run_id", "")) or None
                        ),
                    )
                except ttess.UploadError as exc:
                    self._send_json(
                        {"error": str(exc), "code": exc.code}, HTTPStatus.BAD_REQUEST
                    )
                    return
                result["exam_title"] = destination.get("exam_title")
                result["local_run_id"] = report["run_id"]
                self._send_json(result)
                return
            elif path == "/api/sessions/delete":
                self.controller.remove_sessions([int(body.get("id", 0))])
                self._send_json({"sessions": self.store.list_sessions()})
                return
            elif path == "/api/storage/prune":
                days = int(body.get("days", 365))
                doomed = self.store.sessions_older_than(days)
                if body.get("preview"):
                    self._send_json({"count": len(doomed), "days": days})
                    return
                result = self.controller.remove_sessions(
                    [int(item["id"]) for item in doomed]
                )
                result["storage"] = self.store.storage_report()
                result["sessions_list"] = self.store.list_sessions()
                self._send_json(result)
                return
            elif path == "/api/sessions/rename":
                self.store.update_session(
                    int(body.get("id", 0)), name=str(body.get("name", ""))
                )
                self._send_json({"sessions": self.store.list_sessions()})
                return
            elif path == "/api/resolve-review":
                self.controller.resolve_review(
                    int(body.get("id", 0)),
                    dict(body.get("resolutions", {})),
                    str(body.get("student_id", "")),
                    str(body.get("student_name", "")),
                )
            else:
                self._send_json({"error": "Not found"}, HTTPStatus.NOT_FOUND)
                return
            self._send_json(self.controller.snapshot())
        except Exception as exc:
            self._send_json({"error": str(exc)}, HTTPStatus.BAD_REQUEST)


def build_server(
    host: str = "127.0.0.1",
    port: int = 8765,
    capture_dir: str | None = None,
) -> tuple[ThreadingHTTPServer, ScannerController, threading.Event]:
    """Wire up a server without running it.

    Port 0 asks the OS for a free port, which is what the native app uses:
    it never has to coordinate with another instance over a fixed port.
    """
    store = Store(paths.database_path(capture_dir))
    # Where this copy uploads to, if the teacher has set it. The store edition
    # has no default, so without this it would have nowhere to send anything.
    ttess.set_endpoint(store.get_setting(ENDPOINT_SETTING, "") or "")
    ttess.set_site(store.get_setting(SITE_SETTING, "") or "")
    controller = ScannerController(paths.capture_root(capture_dir), store)
    shutdown_requested = threading.Event()
    DataLinkRequestHandler.controller = controller
    DataLinkRequestHandler.shutdown_requested = shutdown_requested
    server = ThreadingHTTPServer((host, port), DataLinkRequestHandler)
    return server, controller, shutdown_requested


def serve(
    host: str = "127.0.0.1",
    port: int = 8765,
    open_browser: bool = True,
    capture_dir: str | None = None,
) -> int:
    """Run the workspace until Ctrl+C, Quit, or the process is terminated.

    If the port is already taken, a scanner workspace is assumed to be running
    already: point the browser at it instead of failing with a stack trace.
    """
    url = f"http://{host}:{port}"

    try:
        server, controller, shutdown_requested = build_server(host, port, capture_dir)
    except OSError as exc:
        if exc.errno != errno.EADDRINUSE:
            raise
        print(f"A DataLink Scanner workspace is already running at {url}", flush=True)
        if open_browser:
            webbrowser.open(url)
        return 0

    print(f"DataLink Scanner is running at {url}", flush=True)
    print(f"Sessions are saved to {controller.capture_root}", flush=True)
    print("Keep this window open. Press Control-C to stop.", flush=True)
    if open_browser:
        threading.Timer(0.5, lambda: webbrowser.open(url)).start()

    watcher = threading.Thread(
        target=lambda: (shutdown_requested.wait(), server.shutdown()),
        daemon=True,
    )
    watcher.start()

    # serve_forever() is pure Python, so an ordinary handler runs promptly.
    # Without this a `kill` skips the finally block below and the database is
    # left with an unmerged write-ahead log.
    for name in ("SIGTERM", "SIGHUP"):
        number = getattr(signal, name, None)
        if number is None:
            continue
        try:
            signal.signal(number, lambda *_: shutdown_requested.set())
        except ValueError:
            # Not the main thread; the caller owns signal handling.
            pass
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping DataLink Scanner.")
    finally:
        shutdown_requested.set()
        controller.disconnect()
        server.server_close()
        controller.store.close()
    return 0

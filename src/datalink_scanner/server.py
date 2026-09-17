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
import signal
import threading
import time
import webbrowser
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from . import paths
from .store import Store
from .interface import (
    DEFAULT_ANSWER_COUNT,
    MAX_ANSWER_COUNT,
    MIN_ANSWER_COUNT,
    DataLinkError,
    DataLinkFormRecord,
    DirectDataLinkScanner,
    append_jsonl,
    discover_port,
    validate_question_count,
)


def safe_export_filename(test_name: str) -> str:
    cleaned = "".join(
        character
        if character.isascii() and (character.isalnum() or character in " ._-")
        else "_"
        for character in test_name.strip()
    ).strip(" .")
    cleaned = cleaned or "datalink-session"
    return cleaned if cleaned.lower().endswith(".csv") else f"{cleaned}.csv"


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
            scanner = DirectDataLinkScanner(port, question_count=question_count)
            scanner.open()
            initialization = scanner.initialize()
            transition = scanner.enter_data_collection()
            stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            self.capture_root.mkdir(parents=True, exist_ok=True)
            output_path = self.capture_root / f"browser_session_{stamp}.jsonl"
            session_id = self.store.create_session(
                self.store.get_setting("test_name"),
                self.store.get_setting("selected_class"),
                question_count,
                log_path=str(output_path),
            )
            with self._lock:
                self._scanner = scanner
                self._port = port
                self._output_path = output_path
                self._session_id = session_id
                self._question_count = question_count
                self._state = "connected"
                self._stop.clear()
            for command, reply in initialization + transition:
                self._log(f"{command} → {reply}", "protocol")
            self._log("Data Collection is active. Feed one sheet at a time.", "success")
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

    def _read_loop(self) -> None:
        while not self._stop.is_set():
            with self._lock:
                scanner = self._scanner
                output_path = self._output_path
            if scanner is None:
                return
            try:
                records, messages = scanner.read_available()
                for message in messages:
                    self._log(f"Scanner: {message}", "protocol")
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
                return
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
            }
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
        self._record_scan(public)
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
        self._stop.set()
        with self._lock:
            scanner = self._scanner
            session_id = self._session_id
            self._scanner = None
            self._session_id = None
            self._state = "disconnected"
            self._port = None
            self._error = None
        if session_id is not None:
            self.store.update_session(session_id, finished=True)
            self.store.prune_empty_sessions()
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
            self._records.clear()
            self._pending_reviews.clear()
            self._pending_record_objects.clear()
        self._log("The on-screen session was cleared.")

    def add_demo_record(self, question_count: int) -> None:
        question_count = validate_question_count(question_count)
        choices = ["A", "B", "C", "D", "E"]
        responses = [choices[index % 5] for index in range(question_count)]
        with self._lock:
            self._question_count = question_count
            number = len(self._records) + 1
            self._records.append(
                {
                    "number": number,
                    "received_at": datetime.now(timezone.utc).isoformat(),
                    "responses": responses,
                    "answered_count": question_count,
                    "demo": True,
                    "role": "key" if not self._records else "student",
                    "student_id": None if not self._records else str(900000 + number),
                    "student_name": None if not self._records else f"Demo Student {number - 1}",
                }
            )
        self._log(f"Added demo sheet {number}.", "success")

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
            self._send_json(
                {
                    "test_name": self.store.get_setting("test_name"),
                    "selected_class": self.store.get_setting("selected_class"),
                    "question_count": self.store.get_setting("question_count"),
                }
            )
            return
        if path == "/api/sessions":
            self._send_json({"sessions": self.store.list_sessions()})
            return
        if path == "/api/storage":
            self._send_json(self.store.storage_report())
            return
        session_id = self._session_id_from(path, "/export.csv")
        if session_id is not None:
            session = self.store.session(session_id)
            if session is None:
                self._send_json({"error": "No such session"}, HTTPStatus.NOT_FOUND)
                return
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
            session["scans"] = self.store.session_scans(session_id)
            self._send_json(session)
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
            elif path == "/api/disconnect":
                self.controller.disconnect()
            elif path == "/api/clear":
                self.controller.clear()
            elif path == "/api/quit":
                self.controller.disconnect()
                self._send_json({"stopping": True})
                self.shutdown_requested.set()
                return
            elif path == "/api/demo":
                self.controller.add_demo_record(
                    body.get("question_count", DEFAULT_ANSWER_COUNT)
                )
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
                for key in ("test_name", "selected_class", "question_count"):
                    if key in body:
                        self.store.set_setting(key, str(body[key]))
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

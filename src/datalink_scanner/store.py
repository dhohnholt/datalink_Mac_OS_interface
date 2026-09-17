"""SQLite storage for classes, settings and scan history.

Everything that has to outlive a launch lives here rather than in the page.
The window's origin changes every launch — the server binds an ephemeral port —
so browser storage is not a safe home for a class roster.

One connection guarded by a lock: the HTTP server is threaded, but the write
volume here is a handful of rows per scanned sheet.
"""

from __future__ import annotations

import json
import sqlite3
import threading
from datetime import datetime, timedelta, timezone
from pathlib import Path


SCHEMA = """
CREATE TABLE IF NOT EXISTS settings (
    key   TEXT PRIMARY KEY,
    value TEXT
);

CREATE TABLE IF NOT EXISTS classes (
    id         INTEGER PRIMARY KEY,
    name       TEXT NOT NULL UNIQUE,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS students (
    id         INTEGER PRIMARY KEY,
    class_id   INTEGER NOT NULL REFERENCES classes(id) ON DELETE CASCADE,
    student_id TEXT NOT NULL,
    name       TEXT NOT NULL,
    position   INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
    id             INTEGER PRIMARY KEY,
    name           TEXT NOT NULL DEFAULT '',
    class_name     TEXT NOT NULL DEFAULT '',
    question_count INTEGER NOT NULL,
    started_at     TEXT NOT NULL,
    ended_at       TEXT,
    log_path       TEXT,
    analysis_run_id      TEXT,
    analysis_fingerprint TEXT,
    source         TEXT NOT NULL DEFAULT 'datalink'
);

CREATE TABLE IF NOT EXISTS scans (
    id             INTEGER PRIMARY KEY,
    session_id     INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    number         INTEGER NOT NULL,
    role           TEXT NOT NULL,
    student_id     TEXT,
    student_name   TEXT,
    received_at    TEXT NOT NULL,
    answered_count INTEGER NOT NULL,
    responses      TEXT NOT NULL,
    demo           INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS scans_by_session ON scans(session_id, number);
CREATE INDEX IF NOT EXISTS students_by_class ON students(class_id, position);
"""


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


class Store:
    def __init__(self, path: str | Path) -> None:
        self.path = str(path)
        if self.path != ":memory:":
            Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._connection = sqlite3.connect(self.path, check_same_thread=False)
        self._connection.row_factory = sqlite3.Row
        with self._lock:
            self._connection.execute("PRAGMA foreign_keys = ON")
            self._connection.execute("PRAGMA journal_mode = WAL")
            self._connection.executescript(SCHEMA)
            self._migrate()
            self._connection.commit()

    def _migrate(self) -> None:
        """Add columns to a database created by an earlier version."""
        columns = {
            row["name"]
            for row in self._connection.execute("PRAGMA table_info(sessions)")
        }
        if "log_path" not in columns:
            self._connection.execute("ALTER TABLE sessions ADD COLUMN log_path TEXT")
        # The run_id identifies one scoring run to T-TESS. It is kept so a
        # retry reuses it, and regenerated only when the scans behind it change.
        if "analysis_run_id" not in columns:
            self._connection.execute(
                "ALTER TABLE sessions ADD COLUMN analysis_run_id TEXT"
            )
        if "analysis_fingerprint" not in columns:
            self._connection.execute(
                "ALTER TABLE sessions ADD COLUMN analysis_fingerprint TEXT"
            )
        # How the sheets were read. Everything created before this column
        # existed came off the scanner itself, which is the default.
        if "source" not in columns:
            self._connection.execute(
                "ALTER TABLE sessions ADD COLUMN source TEXT NOT NULL "
                "DEFAULT 'datalink'"
            )

    def close(self) -> None:
        """Fold the write-ahead log back into the database before closing.

        Without this the app leaves a -wal and a -shm file behind on every
        quit, and the .sqlite3 file itself stays almost empty while the real
        data sits in the log.
        """
        with self._lock:
            try:
                self._connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            except sqlite3.Error:
                pass
            self._connection.close()

    # ------------------------------------------------------------- settings

    def get_setting(self, key: str, default: str = "") -> str:
        with self._lock:
            row = self._connection.execute(
                "SELECT value FROM settings WHERE key = ?", (key,)
            ).fetchone()
        return row["value"] if row is not None else default

    def set_setting(self, key: str, value: str) -> None:
        with self._lock:
            self._connection.execute(
                "INSERT INTO settings(key, value) VALUES(?, ?) "
                "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                (key, value),
            )
            self._connection.commit()

    # -------------------------------------------------------------- classes

    def list_classes(self) -> list[dict]:
        with self._lock:
            rows = self._connection.execute(
                "SELECT id, name FROM classes ORDER BY name COLLATE NOCASE"
            ).fetchall()
            result = []
            for row in rows:
                students = self._connection.execute(
                    "SELECT student_id, name FROM students "
                    "WHERE class_id = ? ORDER BY position",
                    (row["id"],),
                ).fetchall()
                result.append(
                    {
                        "name": row["name"],
                        "students": [
                            {"id": s["student_id"], "name": s["name"]} for s in students
                        ],
                    }
                )
        return result

    def get_class(self, name: str) -> dict | None:
        return next((item for item in self.list_classes() if item["name"] == name), None)

    def save_class(
        self, name: str, students: list[dict], original_name: str | None = None
    ) -> None:
        """Create or rename-and-replace a class. Students are stored in the
        order given, which is the order the workspace walks through them."""
        name = name.strip()
        if not name:
            raise ValueError("Enter a class name")
        cleaned: list[tuple[str, str]] = []
        seen: set[str] = set()
        for entry in students:
            student_id = str(entry.get("id", "")).strip()
            student_name = str(entry.get("name", "")).strip()
            if not student_id.isdigit() or not student_name:
                raise ValueError(f"Fix roster line: {student_id} {student_name}".strip())
            if student_id in seen:
                raise ValueError(f"Student ID {student_id} appears more than once")
            seen.add(student_id)
            cleaned.append((student_id, student_name))

        with self._lock:
            previous = (original_name or name).strip()
            row = self._connection.execute(
                "SELECT id FROM classes WHERE name = ?", (previous,)
            ).fetchone()
            clash = self._connection.execute(
                "SELECT id FROM classes WHERE name = ? COLLATE NOCASE", (name,)
            ).fetchone()
            if clash is not None and (row is None or clash["id"] != row["id"]):
                raise ValueError("A class with that name already exists")

            if row is None:
                cursor = self._connection.execute(
                    "INSERT INTO classes(name, created_at) VALUES(?, ?)", (name, _now())
                )
                class_id = cursor.lastrowid
            else:
                class_id = row["id"]
                self._connection.execute(
                    "UPDATE classes SET name = ? WHERE id = ?", (name, class_id)
                )
                self._connection.execute(
                    "DELETE FROM students WHERE class_id = ?", (class_id,)
                )
            self._connection.executemany(
                "INSERT INTO students(class_id, student_id, name, position) "
                "VALUES(?, ?, ?, ?)",
                [
                    (class_id, student_id, student_name, index)
                    for index, (student_id, student_name) in enumerate(cleaned)
                ],
            )
            self._connection.commit()

    def delete_class(self, name: str) -> None:
        with self._lock:
            self._connection.execute("DELETE FROM classes WHERE name = ?", (name,))
            self._connection.commit()

    # ------------------------------------------------------------- sessions

    def create_session(
        self,
        name: str,
        class_name: str,
        question_count: int,
        log_path: str | None = None,
        source: str = "datalink",
    ) -> int:
        with self._lock:
            cursor = self._connection.execute(
                "INSERT INTO sessions(name, class_name, question_count, started_at, "
                "log_path, source) VALUES(?, ?, ?, ?, ?, ?)",
                (
                    name or "",
                    class_name or "",
                    question_count,
                    _now(),
                    log_path,
                    source or "datalink",
                ),
            )
            self._connection.commit()
            return int(cursor.lastrowid)

    def update_session(
        self,
        session_id: int,
        name: str | None = None,
        class_name: str | None = None,
        finished: bool = False,
    ) -> None:
        assignments, values = [], []
        if name is not None:
            assignments.append("name = ?")
            values.append(name)
        if class_name is not None:
            assignments.append("class_name = ?")
            values.append(class_name)
        if finished:
            assignments.append("ended_at = ?")
            values.append(_now())
        if not assignments:
            return
        values.append(session_id)
        with self._lock:
            self._connection.execute(
                f"UPDATE sessions SET {', '.join(assignments)} WHERE id = ?", values
            )
            self._connection.commit()

    def remember_run_id(self, session_id: int, run_id: str, fingerprint: str) -> None:
        with self._lock:
            self._connection.execute(
                "UPDATE sessions SET analysis_run_id = ?, analysis_fingerprint = ? "
                "WHERE id = ?",
                (run_id, fingerprint, session_id),
            )
            self._connection.commit()

    def add_scan(self, session_id: int, scan: dict) -> int:
        with self._lock:
            cursor = self._connection.execute(
                "INSERT INTO scans(session_id, number, role, student_id, student_name, "
                "received_at, answered_count, responses, demo) "
                "VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    session_id,
                    int(scan.get("number", 0)),
                    str(scan.get("role", "student")),
                    scan.get("student_id"),
                    scan.get("student_name"),
                    str(scan.get("received_at", _now())),
                    int(scan.get("answered_count", 0)),
                    json.dumps(list(scan.get("responses", []))),
                    1 if scan.get("demo") else 0,
                ),
            )
            self._connection.commit()
            return int(cursor.lastrowid)

    def update_scan(
        self,
        session_id: int,
        number: int,
        student_id: str | None = None,
        student_name: str | None = None,
        responses: list[str] | None = None,
    ) -> bool:
        """Correct one stored sheet.

        The scanner is accurate, but a sheet can still be fed with a smudged
        ID, and an answer key can be bubbled wrong. Editing the stored row is
        enough: the analysis is computed from these rows on demand, so it
        follows automatically.
        """
        assignments, values = [], []
        if student_id is not None:
            assignments.append("student_id = ?")
            values.append(student_id or None)
        if student_name is not None:
            assignments.append("student_name = ?")
            values.append(student_name or None)
        if responses is not None:
            assignments.append("responses = ?")
            values.append(json.dumps(list(responses)))
            assignments.append("answered_count = ?")
            values.append(sum(1 for value in responses if value))
        if not assignments:
            return False
        values.extend([session_id, number])
        with self._lock:
            cursor = self._connection.execute(
                f"UPDATE scans SET {', '.join(assignments)} "
                "WHERE session_id = ? AND number = ?",
                values,
            )
            self._connection.commit()
            return cursor.rowcount > 0

    def list_sessions(self) -> list[dict]:
        with self._lock:
            rows = self._connection.execute(
                "SELECT s.id, s.name, s.class_name, s.question_count, s.started_at, "
                "       s.ended_at, s.source, COUNT(c.id) AS scan_count "
                "FROM sessions s LEFT JOIN scans c ON c.session_id = s.id "
                "GROUP BY s.id ORDER BY s.started_at DESC"
            ).fetchall()
        return [dict(row) for row in rows]

    def session(self, session_id: int) -> dict | None:
        with self._lock:
            row = self._connection.execute(
                "SELECT id, name, class_name, question_count, started_at, ended_at, "
                "       log_path, analysis_run_id, analysis_fingerprint, source "
                "FROM sessions WHERE id = ?",
                (session_id,),
            ).fetchone()
        return dict(row) if row is not None else None

    def session_scans(self, session_id: int) -> list[dict]:
        with self._lock:
            rows = self._connection.execute(
                "SELECT number, role, student_id, student_name, received_at, "
                "       answered_count, responses, demo "
                "FROM scans WHERE session_id = ? ORDER BY number",
                (session_id,),
            ).fetchall()
        scans = []
        for row in rows:
            scan = dict(row)
            scan["responses"] = json.loads(scan["responses"])
            scan["demo"] = bool(scan["demo"])
            scans.append(scan)
        return scans

    def delete_session(self, session_id: int) -> None:
        with self._lock:
            self._connection.execute("DELETE FROM sessions WHERE id = ?", (session_id,))
            self._connection.commit()

    def prune_empty_sessions(self) -> int:
        """Drop sessions that never received a sheet. Connecting to check the
        scanner should not litter the history."""
        with self._lock:
            cursor = self._connection.execute(
                "DELETE FROM sessions WHERE id NOT IN (SELECT DISTINCT session_id FROM scans)"
            )
            self._connection.commit()
            return cursor.rowcount

    # -------------------------------------------------------------- storage

    def storage_report(self) -> dict:
        """What this app is keeping, and where."""
        with self._lock:
            counts = self._connection.execute(
                "SELECT (SELECT COUNT(*) FROM sessions) AS sessions, "
                "       (SELECT COUNT(*) FROM scans)    AS scans, "
                "       (SELECT COUNT(*) FROM classes)  AS classes, "
                "       (SELECT MIN(started_at) FROM sessions) AS oldest"
            ).fetchone()
        report = dict(counts)
        directory = Path(self.path).parent if self.path != ":memory:" else None
        database = 0
        logs = 0
        log_count = 0
        if directory is not None and directory.is_dir():
            for entry in directory.glob("library.sqlite3*"):
                database += entry.stat().st_size
            for entry in directory.glob("*.jsonl"):
                logs += entry.stat().st_size
                log_count += 1
        report["database_bytes"] = database
        report["log_bytes"] = logs
        report["log_files"] = log_count
        report["total_bytes"] = database + logs
        report["directory"] = str(directory) if directory else ""
        return report

    def sessions_older_than(self, days: int) -> list[dict]:
        """Sessions started more than `days` ago, with their log files."""
        if days < 0:
            raise ValueError("Days must not be negative")
        cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
        with self._lock:
            rows = self._connection.execute(
                "SELECT id, name, started_at, log_path FROM sessions "
                "WHERE started_at < ? ORDER BY started_at",
                (cutoff,),
            ).fetchall()
        return [dict(row) for row in rows]

    def delete_sessions(self, session_ids: list[int]) -> int:
        if not session_ids:
            return 0
        placeholders = ",".join("?" * len(session_ids))
        with self._lock:
            cursor = self._connection.execute(
                f"DELETE FROM sessions WHERE id IN ({placeholders})", session_ids
            )
            self._connection.commit()
            return cursor.rowcount

    def vacuum(self) -> None:
        """Hand freed pages back to the filesystem after a bulk delete."""
        with self._lock:
            self._connection.execute("VACUUM")
            self._connection.commit()

    # ------------------------------------------------------------ migration

    def import_classes(self, classes: list[dict]) -> list[str]:
        """Adopt classes that a browser still holds in localStorage.

        Only names the database does not already know are taken, so running it
        again after an edit here cannot clobber the edit.
        """
        existing = {item["name"] for item in self.list_classes()}
        imported = []
        for entry in classes:
            name = str(entry.get("name", "")).strip()
            if not name or name in existing:
                continue
            try:
                self.save_class(name, list(entry.get("students", [])))
            except ValueError:
                continue
            imported.append(name)
        return imported

#!/usr/bin/env python3
"""Direct interface for the Apperson DataLink 1200 scanner.

The command sequence and record framing in this module come from USBPcap
captures made against DataLink Connect 4.5. Scanner writes are deliberately
gated behind --acknowledge-writes until the sequence is proven on macOS.
"""

from __future__ import annotations

import csv
import glob
import json
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path


BAUD_RATE = 38_400
EXPECTED_FIELD_COUNT = 211
ANSWER_START = 10
STUDENT_ID_FIELD = 0
DEFAULT_ANSWER_COUNT = 50
MIN_ANSWER_COUNT = 1
# A record carries EXPECTED_FIELD_COUNT fields with answers starting at
# ANSWER_START, so the wire format itself allows 201. Testing confirmed reads
# well past 75, but forms in use are far shorter and a runaway count would
# silently pull protocol metadata in as answers, so the app caps it here.
MAX_ANSWER_COUNT = 100
PROTOCOL_ANSWER_CEILING = EXPECTED_FIELD_COUNT - ANSWER_START

# Exact host payloads observed during the initial DataLink Connect session.
INITIALIZATION_COMMANDS = (
    b"V",
    b"R1",
    b"R5",
    b"T2",
    b"N8",
    b"A8",
    b"M8",
    b"M0",
    b"Q1",
    b"P5",
    b"X7",
    b"T4",
)

# Exact transition repeatedly observed around Data Collection activity.
# M6 is the only command absent from the ordinary reinitialization sequence.
DATA_COLLECTION_COMMANDS = (b"R1", b"R5", b"M6", b"N8", b"A8", b"M8", b"M0")

# Anything the scanner says that is not a form record. `OK` is its reply to a
# command and is ordinary; everything else means a sheet did not go through,
# and the teacher has to see it in plain words rather than as two letters.
#
# The wording is Apperson's own. DataLink Connect's string table pairs each
# message with a key that carries the scanner's code: `kD1InsertSide1` and
# `kD2InsertSide2`. HYPOTHESIS per docs/PROTOCOL.md's convention — the codes
# are read off those key names, not off a capture, because no side-2 event
# occurs in shark.pcapng or shark2.pcapng. An unrecognised line is passed
# through verbatim and still flagged, so a wrong guess here costs nothing.
UNREADABLE_RECORD = "Unreadable form record skipped"

SCANNER_MESSAGES = {
    "D1": (
        "The scanner is waiting for side 1 of a two-sided form. "
        "It will not take another sheet until it has it — use Reset scanner "
        "to take it back to a fresh sheet."
    ),
    "D2": (
        "The scanner is waiting for side 2 of a two-sided form. "
        "It will not take another sheet until it has it — feed the back of "
        "that sheet, or use Reset scanner if the form is one-sided."
    ),
}


def describe_message(text: str) -> tuple[str, str]:
    """Classify one non-record line from the scanner.

    Returns the activity kind and what to show. `OK` is the reply to a command
    and belongs with the protocol chatter; anything else stops the feed and so
    is a warning the teacher sees without turning protocol details on.
    """
    cleaned = text.strip()
    if not cleaned or cleaned == "OK" or cleaned.endswith("OK"):
        return "protocol", f"Scanner: {cleaned}"
    if cleaned.startswith(UNREADABLE_RECORD):
        # The parser's own note about a line it could not read, already in
        # plain words. Wrapping it again would read as two errors.
        return "error", cleaned
    described = SCANNER_MESSAGES.get(cleaned.upper())
    if described:
        return "warning", described
    return "warning", f"The scanner sent an unexpected message: {cleaned}"


class DataLinkError(RuntimeError):
    pass


def validate_question_count(value: object) -> int:
    """Coerce and range-check a questions-per-form value."""
    try:
        count = int(value)
    except (TypeError, ValueError):
        raise DataLinkError("Questions per form must be a whole number") from None
    if not MIN_ANSWER_COUNT <= count <= MAX_ANSWER_COUNT:
        raise DataLinkError(
            f"Questions per form must be between {MIN_ANSWER_COUNT} and "
            f"{MAX_ANSWER_COUNT}"
        )
    return count


@dataclass(frozen=True)
class DataLinkFormRecord:
    received_at: str
    fields: list[str]
    responses: list[str]

    @classmethod
    def from_line(cls, line: bytes, question_count: int = DEFAULT_ANSWER_COUNT) -> "DataLinkFormRecord":
        question_count = validate_question_count(question_count)
        try:
            text = line.decode("ascii")
        except UnicodeDecodeError as exc:
            raise DataLinkError("Form record is not ASCII") from exc

        fields = next(csv.reader([text]))
        if len(fields) != EXPECTED_FIELD_COUNT:
            raise DataLinkError(
                f"Expected {EXPECTED_FIELD_COUNT} CSV fields; received {len(fields)}"
            )

        responses = [value.strip() for value in fields[ANSWER_START : ANSWER_START + question_count]]
        invalid = [
            value
            for value in responses
            if value not in {"", "*"}
            and not all(character in "ABCDE" for character in value)
        ]
        if invalid:
            raise DataLinkError(f"Unexpected response values: {sorted(set(invalid))}")

        return cls(
            received_at=datetime.now(timezone.utc).isoformat(),
            fields=fields,
            responses=responses,
        )

    def public_dict(self, include_raw_fields: bool = False) -> dict[str, object]:
        scanner_id = self.fields[STUDENT_ID_FIELD].strip()
        result: dict[str, object] = {
            "received_at": self.received_at,
            "responses": self.responses,
            "answered_count": sum(bool(value) for value in self.responses),
            "scanner_id": scanner_id if scanner_id.isdigit() else None,
        }
        if include_raw_fields:
            result["fields"] = self.fields
        return result


class DataLinkStreamParser:
    """Incrementally separates control replies from complete form records."""

    # How long an unterminated line may sit in the buffer before it is given up
    # on. The scanner ends everything it says with CRLF, so a fragment older
    # than this is either a message it did not finish or line noise. Either way
    # it must not stay: the next record would be appended to it and read as one
    # long malformed line, costing a sheet that went through perfectly well.
    STALE_FRAGMENT_SECONDS = 2.0

    def __init__(self, question_count: int = DEFAULT_ANSWER_COUNT) -> None:
        self.question_count = validate_question_count(question_count)
        self._buffer = bytearray()
        self._fragment_since: float | None = None

    def feed(self, data: bytes) -> tuple[list[DataLinkFormRecord], list[str]]:
        self._buffer.extend(data)
        records: list[DataLinkFormRecord] = []
        messages: list[str] = []

        while True:
            boundary = self._buffer.find(b"\r\n")
            if boundary < 0:
                break
            line = bytes(self._buffer[:boundary])
            del self._buffer[: boundary + 2]
            if not line:
                continue
            if line.count(b",") >= self.question_count:
                # One unreadable line must not take the rest of the read with
                # it. Raising here used to discard every record already parsed
                # out of the same chunk, and those sheets were gone: the bytes
                # had been consumed and the paper had already passed through.
                try:
                    records.append(
                        DataLinkFormRecord.from_line(line, self.question_count)
                    )
                except DataLinkError as exc:
                    messages.append(f"{UNREADABLE_RECORD}: {exc}")
            else:
                messages.append(line.decode("ascii", errors="replace"))

        self._fragment_since = (
            None if not self._buffer
            else self._fragment_since if self._fragment_since is not None
            else time.monotonic()
        )
        return records, messages

    def take_stale_fragment(self, now: float | None = None) -> str | None:
        """Give up on a line the scanner never terminated, and return it."""
        if not self._buffer or self._fragment_since is None:
            return None
        now = time.monotonic() if now is None else now
        if now - self._fragment_since < self.STALE_FRAGMENT_SECONDS:
            return None
        fragment = bytes(self._buffer).decode("ascii", errors="replace")
        self._buffer.clear()
        self._fragment_since = None
        return fragment

    @property
    def pending_bytes(self) -> bytes:
        return bytes(self._buffer)


def discover_port() -> str:
    candidates = sorted(
        set(glob.glob("/dev/cu.usbserial*") + glob.glob("/dev/tty.usbserial*"))
    )
    if not candidates:
        raise DataLinkError("No /dev/cu.usbserial* DataLink port was found")
    # macOS exposes the same adapter as both cu.* and tty.*. The cu.* endpoint
    # is the correct callout device for an application initiating a session.
    preferred = [
        path for path in candidates
        if path.startswith("/dev/cu.") and path.endswith("1200")
    ]
    if len(preferred) == 1:
        return preferred[0]
    if len(candidates) == 1:
        return candidates[0]
    raise DataLinkError("Multiple USB serial ports found; select one with --port")


class DirectDataLinkScanner:
    def __init__(
        self,
        port: str,
        response_timeout: float = 1.0,
        question_count: int = DEFAULT_ANSWER_COUNT,
    ) -> None:
        try:
            import serial
        except ImportError as exc:
            raise DataLinkError(
                "pyserial is required; reinstall datalink-scanner or run "
                "pip install pyserial"
            ) from exc

        self._serial_module = serial
        self.port = port
        self.response_timeout = response_timeout
        self.serial = None
        self.parser = DataLinkStreamParser(question_count)

    def open(self) -> None:
        self.serial = self._serial_module.Serial(
            self.port,
            baudrate=BAUD_RATE,
            bytesize=self._serial_module.EIGHTBITS,
            parity=self._serial_module.PARITY_NONE,
            stopbits=self._serial_module.STOPBITS_ONE,
            timeout=0.05,
            write_timeout=1.0,
        )
        # Match the CP210x state recovered from USBPcap immediately before the
        # official Windows application sends V: DTR off and RTS on.
        self.serial.dtr = False
        self.serial.rts = False
        time.sleep(0.15)
        self.serial.reset_input_buffer()
        self.serial.dtr = False
        self.serial.rts = True
        time.sleep(0.25)

    def close(self) -> None:
        if self.serial is not None:
            self.serial.close()
            self.serial = None

    def _require_open(self):
        if self.serial is None:
            raise DataLinkError("Scanner port is not open")
        return self.serial

    def transact(self, command: bytes) -> str:
        connection = self._require_open()
        connection.write(command)
        connection.flush()
        deadline = time.monotonic() + self.response_timeout
        reply = bytearray()
        while time.monotonic() < deadline:
            chunk = connection.read(max(1, connection.in_waiting))
            if chunk:
                reply.extend(chunk)
                if reply.endswith(b"\r\n"):
                    break
        if not reply:
            raise DataLinkError(f"No response to {command.decode('ascii')}")
        return reply.decode("ascii", errors="replace").rstrip("\r\n")

    def initialize(self) -> list[tuple[str, str]]:
        transcript = []
        for command in INITIALIZATION_COMMANDS:
            reply = self.transact(command)
            transcript.append((command.decode("ascii"), reply))
            # Match the spacing visible in the official application's capture.
            # Back-to-back diagnostic queries can make the scanner drop X7.
            time.sleep(0.06)
        if "ADV 1200OK" not in transcript[0][1]:
            raise DataLinkError(f"Unexpected version response: {transcript[0][1]!r}")
        return transcript

    def enter_data_collection(self) -> list[tuple[str, str]]:
        transcript = []
        for command in DATA_COLLECTION_COMMANDS:
            reply = self.transact(command)
            transcript.append((command.decode("ascii"), reply))
            time.sleep(0.06)
        return transcript

    def resynchronize(self) -> list[tuple[str, str]]:
        """Re-send the captured handshake on a port that is already open.

        This is what the teacher does by hand when the scanner stops taking
        sheets: take it out of Data Collection and put it back. The bytes are
        the same ones the handshake already sends, so nothing new is written to
        the device. Anything the scanner was part-way through saying is
        dropped, which is the point — that half-finished prompt is the jam.
        """
        connection = self._require_open()
        connection.reset_input_buffer()
        self.parser = DataLinkStreamParser(self.parser.question_count)
        return self.initialize() + self.enter_data_collection()

    def read_available(self) -> tuple[list[DataLinkFormRecord], list[str]]:
        connection = self._require_open()
        chunk = connection.read(max(1, connection.in_waiting))
        return self.parser.feed(chunk)


def append_jsonl(
    path: Path,
    record: DataLinkFormRecord,
    include_raw_fields: bool,
    extra: dict[str, object] | None = None,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = record.public_dict(include_raw_fields)
    if extra:
        payload.update(extra)
    with path.open("a", encoding="utf-8") as stream:
        json.dump(payload, stream, separators=(",", ":"))
        stream.write("\n")

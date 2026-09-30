#!/usr/bin/env python3
"""Generate the protocol golden files from the real Python implementation.

The Dart port (`packages/datalink_core`) must behave exactly like
`src/datalink_scanner/interface.py`. This script runs that code over a fixed
set of inputs and writes what it did to
`packages/datalink_core/test/goldens/protocol.json`; the Dart tests replay the
same inputs and compare.

Every input here is synthetic. Student IDs are invented, and nothing is read
from `captures/`, so the output is safe to commit.

Run from the repository root with the project's virtualenv:

    .venv/bin/python tools/goldens/make_protocol_goldens.py

Nothing under `src/` is modified; the script only imports it.
"""

from __future__ import annotations

import csv
import io
import json
import sys
import types
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ROOT / "tests"))

from datalink_scanner import interface  # noqa: E402
from datalink_scanner.interface import (  # noqa: E402
    DataLinkError,
    DataLinkFormRecord,
    DataLinkStreamParser,
    DirectDataLinkScanner,
    describe_message,
    validate_question_count,
)
from support import build_fields, build_line  # noqa: E402

OUT = ROOT / "packages" / "datalink_core" / "test" / "goldens" / "protocol.json"


def hx(data: bytes) -> str:
    return data.hex()


def public(record: DataLinkFormRecord) -> dict:
    """What the record exposes, minus the wall-clock timestamp."""
    shown = record.public_dict(include_raw_fields=True)
    shown.pop("received_at")
    return shown


# --------------------------------------------------------------- question count


def question_count_cases() -> list[dict]:
    values = [
        30, 1, 100, 0, -1, 101, 211, "30", " 30 ", "+30", "-5", "3_0", "30_", "_30",
        "3__0", "", "many", "3.0", "0x10", 30.0, 30.9, -0.5, 1e3, None, "١٢",
        True, False,
    ]
    cases = []
    for value in values:
        entry = {"input": value}
        if isinstance(value, float):
            entry["input"] = {"float": repr(value)}
        elif value is None:
            entry["input"] = {"null": True}
        try:
            entry["ok"] = validate_question_count(value)
        except DataLinkError as exc:
            entry["error"] = str(exc)
        cases.append(entry)
    return cases


# ----------------------------------------------------------------------- records


def synthetic_line(responses, student_id="900011", **overrides) -> bytes:
    fields = build_fields(responses, student_id)
    for index, value in overrides.items():
        fields[int(index)] = value
    return ",".join(fields).encode("ascii")


def record_cases() -> list[dict]:
    a50 = ["A"] * 50
    mixed = (["A", "B", "C", "D", "E"] * 10)
    cases = [
        ("all A, 50", synthetic_line(a50), 50),
        ("A-E cycle", synthetic_line(mixed), 50),
        ("blank tail", synthetic_line(["A"] * 47 + ["", "", ""]), 50),
        ("erasure AC", synthetic_line(["AC"] + ["B"] * 49), 50),
        ("asterisk", synthetic_line(["*"] + ["A"] * 49), 50),
        ("count 30 of 75", synthetic_line(["A"] * 75), 30),
        ("count 5 of 100", synthetic_line(["C"] * 100), 5),
        ("count 100", synthetic_line(["A"] * 100), 100),
        ("count 1", synthetic_line(["E"] * 100), 1),
        ("scanner score 024", synthetic_line(["A"] * 30, **{"1": "024"}), 30),
        ("scanner score 000", synthetic_line(["A"] * 30, **{"1": "000"}), 30),
        ("scanner score blank", synthetic_line(["A"] * 50), 50),
        ("scanner score padded", synthetic_line(["A"] * 50, **{"1": " 031 "}), 50),
        ("scanner score nonnumeric", synthetic_line(["A"] * 50, **{"1": "x1"}), 50),
        ("blank student id", synthetic_line(["A"] * 50, student_id=""), 50),
        ("alpha student id", synthetic_line(["A"] * 50, student_id="AB12"), 50),
        ("padded student id", synthetic_line(["A"] * 50, student_id=" 900014 "), 50),
        ("whitespace in answers", synthetic_line([" A ", "\tB", "C\x1f"] + ["A"] * 47), 50),
        ("internal space in answer", synthetic_line(["A C"] + ["A"] * 49), 50),
        ("bad answer Z", synthetic_line(["Z"] + ["A"] * 49), 50),
        ("two bad answers sorted", synthetic_line(["Q", "Z", "Q"] + ["A"] * 47), 50),
        ("lowercase answer", synthetic_line(["a"] + ["A"] * 49), 50),
        ("quote in bad answer", synthetic_line(["It's"] + ["A"] * 49), 50),
        ("backslash in bad answer", synthetic_line(["A\\B"] + ["A"] * 49), 50),
        ("too few fields", b"1,2,3", 50),
        ("too many fields", (",".join([""] * 212)).encode(), 50),
        ("exactly 211 empty", (",".join([""] * 211)).encode(), 50),
        ("non ascii", synthetic_line(["A"] * 50).replace(b"900011", b"\xff\xfe"), 50),
        ("quoted field with comma", None, 50),
        ("quoted field with escaped quote", None, 50),
        ("stray quote mid field", None, 50),
        ("unterminated quote", None, 50),
        ("trailing comma short", b"a,b,", 50),
        ("count 0", synthetic_line(["A"] * 50), 0),
        ("count 101", synthetic_line(["A"] * 50), 101),
        ("count text", synthetic_line(["A"] * 50), "many"),
        ("count numeric string", synthetic_line(["A"] * 50), "30"),
    ]

    # The CSV quirks need hand-built lines, because build_line never quotes.
    def with_field_zero(text: str) -> bytes:
        return (text + "," + ",".join([""] * 210)).encode("ascii")

    substitutions = {
        "quoted field with comma": with_field_zero('"90,0011"'),
        "quoted field with escaped quote": with_field_zero('"9""0"'),
        "stray quote mid field": with_field_zero('9"0'),
        "unterminated quote": with_field_zero('"900'),
    }

    results = []
    for name, line, count in cases:
        if line is None:
            line = substitutions[name]
        entry = {"name": name, "line_hex": hx(line), "question_count": count}
        try:
            entry["ok"] = public(DataLinkFormRecord.from_line(line, count))
        except DataLinkError as exc:
            entry["error"] = str(exc)
        results.append(entry)
    return results


def stray_break_cases() -> list[dict]:
    """Lines Python's csv module refuses.  The port deliberately turns these
    into an ordinary unreadable-record message instead of killing the read
    loop, so the golden records what Python did and the Dart test asserts the
    documented difference."""
    lines = {
        "bare CR": b"9\r00,"  + b"," * 209,
        "bare LF": b"9\n00,"  + b"," * 209,
    }
    out = []
    for name, line in lines.items():
        entry = {"name": name, "line_hex": hx(line)}
        try:
            DataLinkFormRecord.from_line(line, 50)
            entry["python"] = "parsed"
        except DataLinkError as exc:
            entry["python"] = f"DataLinkError: {exc}"
        except csv.Error as exc:
            entry["python"] = f"csv.Error: {exc}"
        out.append(entry)
    return out


# ------------------------------------------------------------------------- stream


class Clock:
    def __init__(self) -> None:
        self.now = 0.0

    def monotonic(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds


def stream_cases() -> list[dict]:
    line = lambda responses, **kw: synthetic_line(responses, **kw)  # noqa: E731
    crlf = b"\r\n"
    k30 = lambda ch: line([ch] * 30)  # noqa: E731
    full = line(["B"] * 50) + crlf
    cases = [
        {
            "name": "control reply then record",
            "question_count": 50,
            "steps": [{"feed": b"ADV 1200OK\r\n" + line(["A"] * 50) + crlf}],
        },
        {
            "name": "record split across reads",
            "question_count": 50,
            "steps": [{"feed": full[i : i + 37]} for i in range(0, len(full), 37)],
        },
        {
            "name": "incomplete trailing data stays buffered",
            "question_count": 50,
            "steps": [{"feed": b"ADV 12"}],
        },
        {
            "name": "multiple records in one read",
            "question_count": 30,
            "steps": [{"feed": k30("A") + crlf + k30("C") + crlf}],
        },
        {
            "name": "empty lines ignored",
            "question_count": 50,
            "steps": [{"feed": b"\r\n\r\nOK\r\n"}],
        },
        {
            "name": "bad line does not cost the good ones",
            "question_count": 30,
            "steps": [{
                "feed": k30("A") + crlf + b",".join([b"x"] * 40) + crlf + k30("C") + crlf
            }],
        },
        {
            "name": "non ascii message is replaced",
            "question_count": 50,
            "steps": [{"feed": b"ab\xffcd\x80\r\n"}],
        },
        {
            "name": "lone CR and LF do not split",
            "question_count": 50,
            "steps": [{"feed": b"a\rb\nc\r\n"}],
        },
        {
            "name": "CR arrives before its LF",
            "question_count": 50,
            "steps": [{"feed": b"OK\r"}, {"feed": b"\nnext\r\n"}],
        },
        {
            "name": "stale fragment given up on",
            "question_count": 30,
            "steps": [
                {"at": 0.0, "feed": b"D2"},
                {"at": 1.0, "stale": True},
                {"at": 2.5, "stale": True},
                {"at": 2.6, "stale": True},
            ],
        },
        {
            "name": "next record survives a dropped fragment",
            "question_count": 30,
            "steps": [
                {"at": 0.0, "feed": b"D2"},
                {"at": 10.0, "stale": True},
                {"at": 10.1, "feed": k30("B") + crlf},
            ],
        },
        {
            "name": "fragment timer restarts only when buffer empties",
            "question_count": 30,
            "steps": [
                {"at": 0.0, "feed": b"D"},
                {"at": 1.5, "feed": b"2"},
                {"at": 2.0, "stale": True},
                {"at": 2.1, "feed": b"\r\n"},
                {"at": 2.2, "feed": b"X"},
                {"at": 3.0, "stale": True},
                {"at": 4.3, "stale": True},
            ],
        },
        {
            "name": "question count 1 treats every comma line as a record",
            "question_count": 1,
            "steps": [{"feed": b"a,b\r\n" + line(["A"] * 50) + crlf}],
        },
    ]

    results = []
    for case in cases:
        clock = Clock()
        interface.time.monotonic = clock.monotonic  # type: ignore[attr-defined]
        parser = DataLinkStreamParser(case["question_count"])
        steps = []
        for step in case["steps"]:
            clock.now = step.get("at", clock.now)
            out = {}
            if "feed" in step:
                records, messages = parser.feed(step["feed"])
                out["feed_hex"] = hx(step["feed"])
                out["records"] = [public(r) for r in records]
                out["messages"] = messages
            if step.get("stale"):
                out["stale"] = parser.take_stale_fragment()
                out["stale_requested"] = True
            out["at"] = clock.now
            out["pending_hex"] = hx(parser.pending_bytes)
            steps.append(out)
        results.append(
            {"name": case["name"], "question_count": case["question_count"], "steps": steps}
        )
    return results


# ---------------------------------------------------------------------- messages


def message_cases() -> list[dict]:
    texts = [
        "OK", "ADV 1200OK", "", "   ", "D1", "D2", "d2", " D2 ", "ZZ9", "\x1fD1\x1f",
        "Unreadable form record skipped: Expected 211 CSV fields; received 40",
        "Unreadable form record skipped", "xOK", "OKx", "Ok",
        "The scanner is fine", "é",
    ]
    out = []
    for text in texts:
        kind, shown = describe_message(text)
        out.append({"text": text, "kind": kind, "shown": shown})
    return out


# -------------------------------------------------------------------------- json


def json_cases() -> list[dict]:
    values = [
        0, 1, -1, 2**62, -(2**62), 0.1, 1.0, 100.0, 1e15, 1e16, 1e17, 1.5e-7,
        0.0001, 0.00001, 123456789.123456789, -0.0, 0.0, 1e22, 5e-324,
        1.7976931348623157e308, 73.3, 66.7, 0.30000000000000004, 1 / 3, 2 / 3,
        1e100, 123456789012345680.0, 1234567890123456.0, 0.5, 12345.678e-10,
        "plain", 'quote"back\\slash', "tab\tnl\nbs\bff\f", "é", "\u2603", "😀",
        "\x00\x1f\x7f\x80", "", True, False, None, [], {}, [1, [2, []]],
        {"b": 1, "a": {"d": [], "c": {}}},
        {"z": [1, 2], "é": 1, "10": 1, "9": 2, "B": 3, "a": 4},
        {"scanner_id": "900011", "responses": ["A", "", "*", "AC"], "n": 3,
         "strength": 0.2917, "confidence": {"1": {"margin": 0.1, "needs_review": False}}},
    ]
    out = []
    for value in values:
        out.append({
            "value": value,
            "default": json.dumps(value),
            "sorted": json.dumps(value, sort_keys=True),
            "compact": json.dumps(value, separators=(",", ":")),
            "indent2": json.dumps(value, indent=2),
            "sorted_indent2": json.dumps(value, indent=2, sort_keys=True),
        })
    return out


# ------------------------------------------------------------ driver with a fake port


REPLIES = {
    b"V": b"ADV 1200OK\r\n",
    b"R1": b"OK\r\n",
    b"R5": b"OK\r\n",
    b"T2": b"5.5\r\n",
    b"N8": b"OK\r\n",
    b"A8": b"OK\r\n",
    b"M8": b"OK\r\n",
    b"M0": b"OK\r\n",
    b"Q1": b"4658\r\n",
    b"P5": b"0009654,0000387,0009654,\r\n",
    b"X7": b"11/22/11 Standard\r\n",
    b"T4": b"S32155\r\n",
    b"M6": b"OK\r\n",
}


class FakeSerial:
    """Just enough of pyserial's Serial, driven by a script and a fake clock.

    An empty read advances the clock by the port's 50 ms timeout, which is what
    a real one would spend waiting, so deadline logic behaves the same way.
    """

    def __init__(self, scenario: dict, clock: Clock, trace: list[str]) -> None:
        self.scenario = scenario
        self.clock = clock
        self.trace = trace
        self.queue = bytearray()
        # Bytes still "on the wire": handed over one chunk per read, which is
        # how a slow reply reaches the driver in pieces.
        self.pending: list[bytes] = []
        self.timeout = 0.05
        self._dtr = None
        self._rts = None
        self.sent: dict[bytes, int] = {}

    # pyserial exposes these as properties the driver assigns to.
    @property
    def dtr(self):
        return self._dtr

    @dtr.setter
    def dtr(self, value):
        self._dtr = value
        self.log(f"dtr={value}")

    @property
    def rts(self):
        return self._rts

    @rts.setter
    def rts(self, value):
        self._rts = value
        self.log(f"rts={value}")

    def log(self, text: str) -> None:
        self.trace.append(f"{self.clock.now:.3f} {text}")

    @property
    def in_waiting(self) -> int:
        return len(self.queue)

    def reset_input_buffer(self) -> None:
        self.queue.clear()
        self.log("reset_input_buffer")

    def write(self, data: bytes) -> int:
        self.log(f"write {data.decode('ascii')}")
        count = self.sent.get(data, 0)
        self.sent[data] = count + 1
        replies = self.scenario.get("replies", {})
        chosen = replies.get(data.decode("ascii"))
        if chosen is None:
            chosen = REPLIES.get(data, b"")
        elif isinstance(chosen, list):
            chosen = chosen[min(count, len(chosen) - 1)]
        else:
            chosen = chosen
        if isinstance(chosen, str):
            chosen = bytes.fromhex(chosen)
        size = self.scenario.get("chunk")
        if size:
            self.pending.extend(
                chosen[i : i + size] for i in range(0, len(chosen), size)
            )
        else:
            self.queue.extend(chosen)
        return len(data)

    def flush(self) -> None:
        self.log("flush")

    def read(self, size: int = 1) -> bytes:
        if not self.queue and self.pending:
            self.queue.extend(self.pending.pop(0))
        if self.queue:
            out = bytes(self.queue[:size])
            del self.queue[: len(out)]
            self.log(f"read {len(out)}")
            return out
        self.clock.now += self.timeout
        self.log("read 0")
        return b""

    def close(self) -> None:
        self.log("close")


def fake_serial_module(scenario: dict, clock: Clock, trace: list[str]):
    module = types.ModuleType("serial")
    module.EIGHTBITS = 8
    module.PARITY_NONE = "N"
    module.STOPBITS_ONE = 1

    def Serial(port, **kwargs):
        trace.append(
            f"{clock.now:.3f} open {port} baud={kwargs['baudrate']} "
            f"bytesize={kwargs['bytesize']} parity={kwargs['parity']} "
            f"stopbits={kwargs['stopbits']} timeout={kwargs['timeout']} "
            f"write_timeout={kwargs['write_timeout']}"
        )
        return FakeSerial(scenario, clock, trace)

    module.Serial = Serial
    return module


def driver_scenarios() -> list[dict]:
    record = synthetic_line(["A"] * 30) + b"\r\n"
    v = b"ADV 1200OK\r\n"
    return [
        {"name": "handshake", "actions": ["open", "initialize", "enter_data_collection"]},
        {
            "name": "handshake with replies dribbled four bytes at a time",
            "actions": ["open", "initialize"],
            "chunk": 4,
        },
        {
            "name": "version retries a dropped character",
            "actions": ["open", "version"],
            "replies": {"V": [b"AV 1200OK\r\n".hex(), v.hex()]},
        },
        {
            "name": "version retries silence",
            "actions": ["open", "version"],
            "replies": {"V": ["", v.hex()]},
        },
        {
            "name": "version gives up",
            "actions": ["open", "version"],
            "replies": {"V": [b"rubbish\r\n".hex()]},
        },
        {
            "name": "version with no answer at all",
            "actions": ["open", "version"],
            "replies": {"V": [""]},
        },
        {
            "name": "transact with no reply",
            "actions": ["open", {"transact": "R1"}],
            "replies": {"R1": [""]},
        },
        {
            "name": "reply without terminator times out but is returned",
            "actions": ["open", {"transact": "R1"}],
            "replies": {"R1": [b"OK".hex()]},
        },
        {"name": "transact before open", "actions": [{"transact": "V"}]},
        {"name": "resynchronize", "actions": ["open", "initialize", "resynchronize"]},
        {
            "name": "read_available reassembles a record",
            "actions": [
                "open",
                {"inject": record[:100].hex()},
                "read_available",
                {"inject": record[100:].hex()},
                "read_available",
            ],
        },
        {"name": "read_available with nothing waiting", "actions": ["open", "read_available"]},
        {"name": "close twice", "actions": ["open", "close", "close"]},
    ]


def run_driver(scenario: dict) -> dict:
    clock = Clock()
    trace: list[str] = []
    interface.time.monotonic = clock.monotonic  # type: ignore[attr-defined]
    interface.time.sleep = clock.sleep  # type: ignore[attr-defined]
    sys.modules["serial"] = fake_serial_module(scenario, clock, trace)
    scanner = DirectDataLinkScanner("/dev/cu.fake", question_count=30)
    results = []
    for action in scenario["actions"]:
        name = action if isinstance(action, str) else next(iter(action))
        entry = {"action": name}
        try:
            if name == "open":
                scanner.open()
            elif name == "close":
                scanner.close()
            elif name == "version":
                entry["result"] = scanner.version()
            elif name == "initialize":
                entry["result"] = scanner.initialize()
            elif name == "enter_data_collection":
                entry["result"] = scanner.enter_data_collection()
            elif name == "resynchronize":
                entry["result"] = scanner.resynchronize()
            elif name == "transact":
                entry["arg"] = action["transact"]
                entry["result"] = scanner.transact(action["transact"].encode("ascii"))
            elif name == "inject":
                scanner.serial.queue.extend(bytes.fromhex(action["inject"]))
                entry["arg"] = action["inject"]
            elif name == "read_available":
                records, messages = scanner.read_available()
                entry["result"] = {
                    "records": [public(r) for r in records],
                    "messages": messages,
                }
            else:
                raise AssertionError(name)
        except DataLinkError as exc:
            entry["error"] = str(exc)
        entry["at"] = round(clock.now, 6)
        results.append(entry)
    return {"name": scenario["name"], "scenario": scenario, "trace": trace, "results": results}


def main() -> int:
    scenarios = driver_scenarios()
    golden = {
        "note": "Generated by tools/goldens/make_protocol_goldens.py from "
                "src/datalink_scanner/interface.py. Synthetic data only.",
        "python": sys.version.split()[0],
        "question_count": question_count_cases(),
        "records": record_cases(),
        "stray_breaks": stray_break_cases(),
        "stream": stream_cases(),
        "messages": message_cases(),
        "json": json_cases(),
        "device_replies": {c.decode(): r.hex() for c, r in REPLIES.items()},
        "driver": [run_driver(s) for s in scenarios],
        "constants": {
            "baud": interface.BAUD_RATE,
            "expected_field_count": interface.EXPECTED_FIELD_COUNT,
            "answer_start": interface.ANSWER_START,
            "initialization": [c.decode() for c in interface.INITIALIZATION_COMMANDS],
            "data_collection": [c.decode() for c in interface.DATA_COLLECTION_COMMANDS],
            "messages": interface.SCANNER_MESSAGES,
        },
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(golden, indent=1, ensure_ascii=True) + "\n")
    print(f"wrote {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

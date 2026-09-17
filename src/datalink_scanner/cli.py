"""The ``datalink-scanner`` command."""

from __future__ import annotations

import argparse
import glob
import os
import sys
from pathlib import Path
from typing import Iterable

from . import __version__, paths
from .interface import (
    BAUD_RATE,
    DEFAULT_ANSWER_COUNT,
    MAX_ANSWER_COUNT,
    MIN_ANSWER_COUNT,
    DataLinkError,
    DataLinkStreamParser,
    DirectDataLinkScanner,
    append_jsonl,
    discover_port,
    validate_question_count,
)

APP_BUNDLE_NAME = "DataLink Scanner.app"


def question_count(value: str) -> int:
    """argparse type: any whole number the app will accept."""
    try:
        return validate_question_count(value)
    except DataLinkError as exc:
        raise argparse.ArgumentTypeError(str(exc)) from None


def _print_transcript(title: str, transcript: Iterable[tuple[str, str]]) -> None:
    print(title)
    for command, reply in transcript:
        print(f"  {command} -> {reply}")


def command_app(args: argparse.Namespace) -> int:
    """Run the native Cocoa app — the default, and what the .app launches."""
    try:
        from .app import run
    except ImportError as exc:
        print(f"The native app needs PyObjC, which is not available: {exc}")
        print("Falling back to the browser workspace.")
        from .server import serve

        return serve(capture_dir=args.capture_dir)
    return run(capture_dir=args.capture_dir)


def command_serve(args: argparse.Namespace) -> int:
    from .server import serve

    return serve(
        host=args.host,
        port=args.port,
        open_browser=not args.no_browser,
        capture_dir=args.capture_dir,
    )


def command_ports(args: argparse.Namespace) -> int:
    candidates = sorted(
        set(glob.glob("/dev/cu.usbserial*") + glob.glob("/dev/tty.usbserial*"))
    )
    if not candidates:
        print("No USB serial ports found.")
        print(
            "Connect the DataLink 1200 by USB. If nothing appears, install the "
            "Silicon Labs CP210x VCP driver and reconnect."
        )
        return 1
    for path in candidates:
        print(path)
    return 0


def command_scan(args: argparse.Namespace) -> int:
    """Headless capture: the browser workspace without the browser."""
    if not args.acknowledge_writes:
        raise DataLinkError(
            "Scanning sends captured commands to the scanner. Re-run with "
            "--acknowledge-writes after confirming the scanner is connected."
        )
    output = args.output or paths.capture_root(args.capture_dir) / "live_scans.jsonl"
    port = args.port or discover_port()
    scanner = DirectDataLinkScanner(
        port,
        response_timeout=args.command_timeout,
        question_count=args.questions,
    )
    print(f"Opening {port} at {BAUD_RATE} 8N1")
    scanner.open()
    try:
        _print_transcript("Initialization:", scanner.initialize())
        _print_transcript("Data Collection transition:", scanner.enter_data_collection())
        print(f"Ready. Feed sheets one at a time; press Ctrl+C to stop.")
        print(f"Writing to {output}")
        while True:
            records, messages = scanner.read_available()
            for message in messages:
                print(f"Scanner message: {message}")
            for record in records:
                append_jsonl(output, record, args.include_raw_fields)
                answered = sum(bool(value) for value in record.responses)
                print(
                    f"Captured form {record.received_at}: "
                    f"{answered}/{len(record.responses)} answered"
                )
    except KeyboardInterrupt:
        print("\nStopped.")
    finally:
        scanner.close()
    return 0


def command_replay(args: argparse.Namespace) -> int:
    """Parse a saved raw byte stream — the offline path, no hardware needed."""
    output = args.output or paths.capture_root(args.capture_dir) / "replay.jsonl"
    parser = DataLinkStreamParser(args.questions)
    count = 0
    with args.source.open("rb") as stream:
        while chunk := stream.read(4096):
            records, messages = parser.feed(chunk)
            for message in messages:
                print(f"Scanner message: {message}")
            for record in records:
                count += 1
                append_jsonl(output, record, args.include_raw_fields)
    if parser.pending_bytes:
        raise DataLinkError(
            f"Replay ended with {len(parser.pending_bytes)} incomplete bytes"
        )
    print(f"Parsed {count} form record(s) into {output}")
    return 0


def command_analyze(args: argparse.Namespace) -> int:
    """Write the item analysis JSON for a saved session."""
    import json

    from .analysis import AnalysisError, analysis_filename, build_session_analysis
    from .store import Store

    store = Store(paths.database_path(args.capture_dir))
    try:
        if args.list:
            for row in store.list_sessions():
                print(
                    f"{row['id']:>4}  {row['started_at'][:16].replace('T', ' ')}  "
                    f"{row['scan_count']:>4} sheets  {row['name'] or '(untitled)'}"
                )
            return 0
        if args.session is None:
            raise DataLinkError("Pass a session id, or --list to see them")
        session = store.session(args.session)
        if session is None:
            raise DataLinkError(f"No session with id {args.session}")
        try:
            report = build_session_analysis(
                session, store.session_scans(args.session), exam_name=args.exam_name
            )
        except AnalysisError as exc:
            raise DataLinkError(str(exc)) from None
        output = args.output or Path(analysis_filename(session))
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(report, indent=2))
        print(
            f"Scored {len(report['students'])} students over "
            f"{len(report['items'])} questions into {output}"
        )
        return 0
    finally:
        store.close()


def find_app_bundle() -> Path | None:
    """Locate the .app that ships beside an installed copy of this package.

    Homebrew lays the virtualenv out as ``<prefix>/libexec`` with the bundle at
    ``<prefix>/DataLink Scanner.app``, so walk a couple of levels up from
    ``sys.prefix``.
    """
    override = os.environ.get("DATALINK_APP_BUNDLE")
    if override:
        candidate = Path(override).expanduser()
        return candidate if candidate.is_dir() else None
    start = Path(sys.prefix).resolve()
    for directory in (start, *start.parents[:2]):
        candidate = directory / APP_BUNDLE_NAME
        if candidate.is_dir():
            return candidate
    return None


def stable_bundle_path(bundle: Path) -> Path:
    """Rewrite a Homebrew Cellar path to the version-independent opt path.

    `brew upgrade` repoints opt/<formula> at the new version and removes the
    old Cellar directory, so a symlink into Cellar would either dangle or keep
    launching the version it was installed with.
    """
    parts = bundle.parts
    if "Cellar" not in parts:
        return bundle
    index = len(parts) - 1 - parts[::-1].index("Cellar")
    if len(parts) <= index + 3:
        return bundle
    candidate = Path(*parts[:index]) / "opt" / parts[index + 1] / bundle.name
    return candidate if candidate.is_dir() else bundle


BUNDLE_IDENTIFIER = "org.davidhohnholt.datalink-scanner"


def bundle_identifier(app: Path) -> str | None:
    import plistlib

    try:
        with (app / "Contents" / "Info.plist").open("rb") as stream:
            return plistlib.load(stream).get("CFBundleIdentifier")
    except (OSError, ValueError, KeyError):
        return None


def move_to_trash(app: Path, label: str = "replaced") -> Path:
    """Move rather than delete, so replacing the wrong thing is recoverable."""
    import shutil
    from datetime import datetime

    trash = Path.home() / ".Trash"
    trash.mkdir(exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    target = trash / f"{app.stem} ({label} {stamp}){app.suffix}"
    # Two replacements in the same second would otherwise collide, and
    # shutil.move puts the second *inside* the first rather than failing.
    attempt = 2
    while target.exists():
        target = trash / f"{app.stem} ({label} {stamp}-{attempt}){app.suffix}"
        attempt += 1
    shutil.move(str(app), str(target))
    return target


def command_install_app(args: argparse.Namespace) -> int:
    """Symlink the bundle into /Applications so `brew upgrade` updates it too."""
    bundle = find_app_bundle()
    if bundle is None:
        raise DataLinkError(
            f"No {APP_BUNDLE_NAME} was found next to this installation. "
            "It ships with the Homebrew formula; set DATALINK_APP_BUNDLE to "
            "point at one built by packaging/make_app_bundle.sh."
        )
    destination = Path(args.applications).expanduser() / APP_BUNDLE_NAME
    if destination.is_symlink():
        destination.unlink()
    elif destination.exists():
        # Very likely an earlier copy of this same app, drag-installed from a
        # .dmg. Refusing leaves the user launching a stale build that Homebrew
        # cannot update - which looks like the app being broken - so replace
        # it, but into the Trash rather than deleting it.
        identifier = bundle_identifier(destination)
        if identifier == BUNDLE_IDENTIFIER or args.force:
            moved = move_to_trash(destination)
            print(f"Moved the previous app to {moved}")
        else:
            raise DataLinkError(
                f"{destination} is a different application "
                f"(bundle id {identifier or 'unknown'}), so it was left alone. "
                "Re-run with --force to replace it anyway."
            )
    target = stable_bundle_path(bundle)
    destination.symlink_to(target)
    print(f"Linked {destination} → {target}")
    print("`brew upgrade datalink-scanner` now updates the app in place.")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="datalink-scanner",
        description="Interface for the Apperson DataLink 1200 optical mark scanner.",
    )
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    sub = parser.add_subparsers(dest="command")

    def add_capture_dir(target: argparse.ArgumentParser) -> None:
        target.add_argument(
            "--capture-dir",
            help="Directory for saved sessions (default: %s)" % paths.capture_root(),
        )

    app_parser = sub.add_parser(
        "app", help="Open the native app window (default when no command is given)"
    )
    add_capture_dir(app_parser)
    app_parser.set_defaults(func=command_app)

    serve_parser = sub.add_parser(
        "serve", help="Serve the workspace to a web browser instead"
    )
    serve_parser.add_argument("--host", default="127.0.0.1")
    serve_parser.add_argument("--port", type=int, default=8765)
    serve_parser.add_argument(
        "--no-browser", action="store_true", help="Start the server without opening a browser"
    )
    add_capture_dir(serve_parser)
    serve_parser.set_defaults(func=command_serve)

    ports_parser = sub.add_parser("ports", help="List USB serial ports macOS can see")
    ports_parser.set_defaults(func=command_ports)

    scan_parser = sub.add_parser("scan", help="Capture sheets from a Terminal, no browser")
    scan_parser.add_argument("--port", help="Serial device; auto-detected when omitted")
    scan_parser.add_argument("--output", type=Path)
    scan_parser.add_argument("--command-timeout", type=float, default=1.0)
    scan_parser.add_argument(
        "--questions",
        type=question_count,
        default=DEFAULT_ANSWER_COUNT,
        metavar=f"{MIN_ANSWER_COUNT}-{MAX_ANSWER_COUNT}",
        help="Questions on each form (default: %(default)s)",
    )
    scan_parser.add_argument("--include-raw-fields", action="store_true")
    scan_parser.add_argument("--acknowledge-writes", action="store_true")
    add_capture_dir(scan_parser)
    scan_parser.set_defaults(func=command_scan)

    replay_parser = sub.add_parser("replay", help="Parse a saved raw serial byte stream")
    replay_parser.add_argument("source", type=Path)
    replay_parser.add_argument("--output", type=Path)
    replay_parser.add_argument(
        "--questions",
        type=question_count,
        default=DEFAULT_ANSWER_COUNT,
        metavar=f"{MIN_ANSWER_COUNT}-{MAX_ANSWER_COUNT}",
        help="Questions on each form (default: %(default)s)",
    )
    replay_parser.add_argument("--include-raw-fields", action="store_true")
    add_capture_dir(replay_parser)
    replay_parser.set_defaults(func=command_replay)

    analyze_parser = sub.add_parser(
        "analyze", help="Write the item analysis JSON for a saved session"
    )
    analyze_parser.add_argument("session", nargs="?", type=int, help="Session id")
    analyze_parser.add_argument("--list", action="store_true", help="List saved sessions")
    analyze_parser.add_argument("--output", type=Path)
    analyze_parser.add_argument("--exam-name")
    add_capture_dir(analyze_parser)
    analyze_parser.set_defaults(func=command_analyze)

    install_parser = sub.add_parser(
        "install-app", help="Symlink DataLink Scanner.app into /Applications"
    )
    install_parser.add_argument("--applications", default="/Applications")
    install_parser.add_argument(
        "--force", action="store_true", help="Replace a real app already installed there"
    )
    install_parser.set_defaults(func=command_install_app)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if getattr(args, "func", None) is None:
        # Bare `datalink-scanner` is the app's double-click entry point.
        args = parser.parse_args(["app", *(argv or [])])
    try:
        return args.func(args)
    except DataLinkError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

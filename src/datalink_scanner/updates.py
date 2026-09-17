"""Check for a newer release, install it, and tidy the copies left behind.

Three things are easy to get wrong here, so they are each handled explicitly:

* An app bundle can exist several times over — dragged from a disk image,
  built locally, linked by Homebrew — and macOS will happily launch whichever
  one the user double-clicks. Finding them all and keeping one is most of the
  work.
* Homebrew's own storage is not ours to move. Old versions in the Cellar are
  removed with `brew cleanup`; anything under a Cellar directory is left alone.
* Nothing is ever deleted. Extra copies go to the Trash, where an unwanted
  sweep can be undone.

Everything in this module is plain Python with injectable side effects so it
can be tested without a network, without Homebrew and without moving any real
application.
"""

from __future__ import annotations

import json
import os
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

from . import __version__
from .cli import (
    APP_BUNDLE_NAME,
    BUNDLE_IDENTIFIER,
    bundle_identifier,
    move_to_trash,
    stable_bundle_path,
)


REPO = "dhohnholt/datalink_Mac_OS_interface"
RELEASES_API = os.environ.get(
    "DATALINK_RELEASES_URL",
    f"https://api.github.com/repos/{REPO}/releases/latest",
)
RELEASES_PAGE = os.environ.get(
    "DATALINK_RELEASES_PAGE", f"https://github.com/{REPO}/releases/latest"
)
FORMULA = os.environ.get("DATALINK_FORMULA", "dhohnholt/datalink/datalink-scanner")
FORMULA_NAME = FORMULA.rsplit("/", 1)[-1]

REQUEST_TIMEOUT_SECONDS = 15.0
UPGRADE_TIMEOUT_SECONDS = 900.0
# Somewhere obvious to look for a stray copy, for the rare Mac where Spotlight
# indexing is off and mdfind returns nothing.
SEARCH_ROOTS = ("/Applications", "~/Applications", "~/Desktop", "~/Downloads")


AUTO_CHECK_KEY = "updates.auto_check"
LAST_CHECK_KEY = "updates.last_check"
CHECK_INTERVAL_SECONDS = float(
    os.environ.get("DATALINK_UPDATE_INTERVAL_SECONDS", 24 * 60 * 60)
)


class UpdateError(RuntimeError):
    """A failure worth showing the user, in their words rather than a trace."""


# ------------------------------------------------------- the daily check


def auto_check_enabled(store) -> bool:
    """On unless the teacher has turned it off in Settings."""
    return store.get_setting(AUTO_CHECK_KEY, "1") != "0"


def set_auto_check(store, enabled: bool) -> None:
    store.set_setting(AUTO_CHECK_KEY, "1" if enabled else "0")


def last_checked(store) -> float:
    try:
        return float(store.get_setting(LAST_CHECK_KEY, "") or 0.0)
    except ValueError:
        return 0.0


def remember_check(store, when: float | None = None) -> None:
    store.set_setting(LAST_CHECK_KEY, repr(time.time() if when is None else when))


def check_is_due(store, now: float | None = None) -> bool:
    if not auto_check_enabled(store):
        return False
    now = time.time() if now is None else now
    last = last_checked(store)
    # A clock that has moved backwards — a restored machine, a timezone fix —
    # must not postpone the next check indefinitely.
    if last > now:
        return True
    return (now - last) >= CHECK_INTERVAL_SECONDS


# --------------------------------------------------------------- versions


def parse_version(text: str) -> tuple[int, ...]:
    """1.3.0, v1.3.0 and 1.3 all compare the way a person would expect."""
    numbers = re.findall(r"\d+", str(text or ""))
    return tuple(int(number) for number in numbers[:4]) or (0,)


def is_newer(candidate: str, current: str = __version__) -> bool:
    left, right = parse_version(candidate), parse_version(current)
    width = max(len(left), len(right))
    left += (0,) * (width - len(left))
    right += (0,) * (width - len(right))
    return left > right


def latest_release(opener=urllib.request.urlopen) -> dict:
    """Ask GitHub what the newest published release is."""
    if not RELEASES_API.lower().startswith("https://"):
        raise UpdateError("The update check must use https.")
    request = urllib.request.Request(
        RELEASES_API,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": f"datalink-scanner/{__version__}",
        },
    )
    try:
        with opener(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
            payload = json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            raise UpdateError(
                "GitHub has no published release for DataLink Scanner yet."
            ) from None
        if exc.code in (403, 429):
            raise UpdateError(
                "GitHub is rate-limiting update checks from this network. "
                "Try again in a few minutes."
            ) from None
        raise UpdateError(f"GitHub returned {exc.code} for the update check.") from None
    except urllib.error.URLError as exc:
        raise UpdateError(
            f"Could not reach GitHub ({exc.reason}). Check the internet connection."
        ) from None
    except TimeoutError:
        raise UpdateError(
            f"GitHub did not answer within {REQUEST_TIMEOUT_SECONDS:.0f} seconds."
        ) from None
    except ValueError:
        raise UpdateError("GitHub sent a reply the app could not read.") from None

    tag = str(payload.get("tag_name") or "").strip()
    if not tag:
        raise UpdateError("GitHub did not report a latest version.")
    return {
        "tag": tag,
        "version": tag.lstrip("vV"),
        "url": str(payload.get("html_url") or RELEASES_PAGE),
        "notes": str(payload.get("body") or ""),
    }


# ------------------------------------------------------- copies on this Mac


def bundle_for(path: os.PathLike | str) -> Path | None:
    """The .app a file lives inside, if any."""
    try:
        current = Path(path).resolve()
    except OSError:
        return None
    for candidate in (current, *current.parents):
        if candidate.suffix == ".app":
            return candidate
    return None


def running_bundle(executable: os.PathLike | str | None = None) -> Path | None:
    return bundle_for(executable or sys.executable)


def bundle_version(app: Path) -> str:
    try:
        data = plistlib.loads((app / "Contents" / "Info.plist").read_bytes())
    except (OSError, ValueError):
        return ""
    return str(data.get("CFBundleShortVersionString") or "")


def spotlight_copies(runner=subprocess.run) -> list[Path]:
    """Every bundle Spotlight knows about with our identifier."""
    try:
        result = runner(
            [
                "/usr/bin/mdfind",
                f"kMDItemCFBundleIdentifier == '{BUNDLE_IDENTIFIER}'",
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return []
    return [
        Path(line) for line in (result.stdout or "").splitlines() if line.strip()
    ]


def installed_copies(runner=subprocess.run, roots=SEARCH_ROOTS) -> list[Path]:
    """Locate every copy of this app, Spotlight first and the usual places after."""
    candidates = list(spotlight_copies(runner))
    candidates += [Path(root).expanduser() / APP_BUNDLE_NAME for root in roots]
    found: dict[str, Path] = {}
    for path in candidates:
        if path.suffix != ".app" or str(path) in found:
            continue
        if not path.is_dir():
            continue
        # A bundle with someone else's identifier is someone else's app, even
        # if Spotlight's index is stale enough to have offered it.
        if bundle_identifier(path) != BUNDLE_IDENTIFIER:
            continue
        found[str(path)] = path
    return sorted(found.values(), key=lambda item: str(item).lower())


def homebrew_prefix() -> Path | None:
    for prefix in (os.environ.get("HOMEBREW_PREFIX"), "/opt/homebrew", "/usr/local"):
        if prefix and (Path(prefix) / "opt" / FORMULA_NAME).is_dir():
            return Path(prefix)
    return None


def homebrew_bundle() -> Path | None:
    """The bundle Homebrew manages, by its version-independent opt path."""
    prefix = homebrew_prefix()
    if prefix is None:
        return None
    candidate = prefix / "opt" / FORMULA_NAME / APP_BUNDLE_NAME
    return candidate if candidate.is_dir() else None


def brew_path() -> str | None:
    found = shutil.which("brew")
    if found:
        return found
    # A GUI app inherits a bare PATH, so `brew` is routinely not on it.
    for candidate in ("/opt/homebrew/bin/brew", "/usr/local/bin/brew"):
        if os.access(candidate, os.X_OK):
            return candidate
    return None


def homebrew_managed() -> bool:
    """True when `brew upgrade` is the right way to update this install."""
    return brew_path() is not None and homebrew_bundle() is not None


def _sort_key(app: Path) -> tuple:
    try:
        modified = app.stat().st_mtime
    except OSError:
        modified = 0.0
    return (parse_version(bundle_version(app)), modified)


def choose_keeper(copies: list[Path], running: Path | None = None) -> Path | None:
    """Decide which copy survives a sweep.

    Homebrew's is preferred whenever it exists, because that is the one
    `brew upgrade` keeps current; a newer copy elsewhere would go stale the
    first time the formula moves.
    """
    managed = homebrew_bundle()
    if managed is not None:
        return managed
    if not copies:
        return running
    ranked = sorted(copies, key=_sort_key, reverse=True)
    best = _sort_key(ranked[0])
    tied = [app for app in ranked if _sort_key(app) == best]
    for app in tied:
        if app.parent == Path("/Applications"):
            return app
    return tied[0]


def duplicates(copies: list[Path], keeper: Path | None) -> list[Path]:
    """The copies a sweep would move to the Trash."""
    if keeper is None:
        return []
    try:
        kept = keeper.resolve()
    except OSError:
        return []
    extra = []
    for path in copies:
        try:
            real = path.resolve()
        except OSError:
            continue
        # The /Applications entry is normally a symlink onto the kept bundle.
        if real == kept:
            continue
        # Old versions inside the Cellar belong to Homebrew; `brew cleanup`
        # removes those, and moving one would break its records.
        if "Cellar" in real.parts:
            continue
        extra.append(path)
    return extra


def survey(runner=subprocess.run, executable=None) -> dict:
    """What is installed, what would be kept, and what would be swept."""
    copies = installed_copies(runner)
    running = running_bundle(executable)
    keeper = choose_keeper(copies, running)
    return {
        "copies": copies,
        "keeper": keeper,
        "duplicates": duplicates(copies, keeper),
        "running": running,
    }


def sweep(extra: list[Path]) -> list[Path]:
    """Move the extra copies to the Trash, and report what actually moved."""
    moved = []
    for app in extra:
        try:
            moved.append(move_to_trash(app, label="older copy"))
        except OSError:
            # A copy on a read-only volume or a mounted disk image cannot be
            # moved; skipping it is better than abandoning the whole sweep.
            continue
    return moved


# ------------------------------------------------------------- installing


def _tail(text: str, lines: int = 12) -> str:
    kept = [line for line in (text or "").splitlines() if line.strip()]
    return "\n".join(kept[-lines:])


def upgrade(runner=subprocess.run) -> str:
    """Run the Homebrew upgrade, without a terminal to answer prompts."""
    brew = brew_path()
    if brew is None:
        raise UpdateError(
            "Homebrew was not found, so the app cannot update itself. "
            f"Download the new version from {RELEASES_PAGE}"
        )
    environment = {
        **os.environ,
        # Nothing is watching stdout, so a prompt would simply hang.
        "HOMEBREW_NO_ENV_HINTS": "1",
        "HOMEBREW_NO_AUTO_UPDATE": "1",
    }
    transcript: list[str] = []
    for arguments in (["update"], ["upgrade", "--yes", FORMULA], ["cleanup", FORMULA_NAME]):
        try:
            result = runner(
                [brew, *arguments],
                capture_output=True,
                text=True,
                timeout=UPGRADE_TIMEOUT_SECONDS,
                stdin=subprocess.DEVNULL,
                env=environment,
            )
        except subprocess.TimeoutExpired:
            raise UpdateError(
                f"`brew {arguments[0]}` was still running after "
                f"{UPGRADE_TIMEOUT_SECONDS / 60:.0f} minutes and was stopped."
            ) from None
        except OSError as exc:
            raise UpdateError(f"Homebrew could not be run: {exc}") from None
        transcript.append(result.stdout or "")
        transcript.append(result.stderr or "")
        # A failed cleanup leaves an old version on disk; that is untidy, not
        # a failed update, so it does not sink the whole operation.
        if result.returncode != 0 and arguments[0] != "cleanup":
            raise UpdateError(
                f"`brew {arguments[0]}` failed.\n\n{_tail(''.join(transcript))}"
            )
    return "".join(transcript)


def relaunch_target(keeper: Path | None, running: Path | None = None) -> Path | None:
    """Where to reopen from: the path that stays valid across upgrades."""
    if keeper is not None:
        linked = Path("/Applications") / APP_BUNDLE_NAME
        try:
            if linked.is_dir() and linked.resolve() == keeper.resolve():
                return linked
        except OSError:
            pass
        return stable_bundle_path(keeper)
    return running


def relaunch_command(bundle: Path, pid: int) -> list[str]:
    """Wait for this process to go, then open the app again."""
    # Bounded so a wedged app cannot leave a shell spinning for the session.
    script = (
        f"for _ in $(seq 1 300); do "
        f"/bin/kill -0 {int(pid)} 2>/dev/null || break; /bin/sleep 0.2; done; "
        f"/usr/bin/open {shlex.quote(str(bundle))}"
    )
    return ["/bin/sh", "-c", script]


def relaunch(bundle: Path, pid: int | None = None, spawn=subprocess.Popen) -> None:
    spawn(
        relaunch_command(bundle, os.getpid() if pid is None else pid),
        start_new_session=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

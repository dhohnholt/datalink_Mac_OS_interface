"""macOS Keychain storage for the T-TESS connection token.

The token is a credential: it goes in the Keychain and nowhere else — not in
the database beside the scans, not in a preferences file, not in a log line.

Calls go through Security.framework directly rather than the `security`
command, because that command takes the password as an argument and would put
the token in the process list for as long as it runs.

They also go through a helper kept at a fixed path. macOS cannot identify an
ad-hoc signed app by its signature, so it records which application may read an
item **by file path** — and Homebrew installs every version under
``Cellar/datalink-scanner/<version>/``, a path that changes with each upgrade.
The teacher was therefore asked for their login password after every update.
A 33 KB copy of the interpreter living at a path that does not change is
trusted once and stays trusted. The token travels to it down a pipe, never as
an argument.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

try:  # not importable when this file is run as the helper
    from . import paths as _paths
except ImportError:  # pragma: no cover - only in helper mode
    _paths = None


class KeychainError(RuntimeError):
    pass


_ERR_ITEM_NOT_FOUND = -25300
_ERR_DUPLICATE_ITEM = -25299
_ERR_USER_CANCELED = -128


def _load():
    path = ctypes.util.find_library("Security")
    if path is None:  # pragma: no cover - macOS always has it
        raise KeychainError("Security.framework is unavailable on this system")
    library = ctypes.CDLL(path)

    library.SecKeychainAddGenericPassword.argtypes = [
        ctypes.c_void_p, ctypes.c_uint32, ctypes.c_char_p,
        ctypes.c_uint32, ctypes.c_char_p,
        ctypes.c_uint32, ctypes.c_char_p, ctypes.c_void_p,
    ]
    library.SecKeychainFindGenericPassword.argtypes = [
        ctypes.c_void_p, ctypes.c_uint32, ctypes.c_char_p,
        ctypes.c_uint32, ctypes.c_char_p,
        ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_void_p),
        ctypes.POINTER(ctypes.c_void_p),
    ]
    library.SecKeychainItemModifyAttributesAndData.argtypes = [
        ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32, ctypes.c_char_p,
    ]
    library.SecKeychainItemDelete.argtypes = [ctypes.c_void_p]
    library.SecKeychainItemFreeContent.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    library.CFRelease.argtypes = [ctypes.c_void_p]
    return library


def _fail(status: int, action: str) -> KeychainError:
    if status == _ERR_USER_CANCELED:
        return KeychainError(f"The Keychain request was cancelled while {action}")
    return KeychainError(f"Keychain error {status} while {action}")


def _get_here(service: str, account: str) -> str | None:
    """Return the stored secret, or None when nothing is stored."""
    library = _load()
    length = ctypes.c_uint32()
    data = ctypes.c_void_p()
    status = library.SecKeychainFindGenericPassword(
        None,
        len(service), service.encode(),
        len(account), account.encode(),
        ctypes.byref(length), ctypes.byref(data), None,
    )
    if status == _ERR_ITEM_NOT_FOUND:
        return None
    if status != 0:
        raise _fail(status, "reading the connection token")
    try:
        return ctypes.string_at(data.value, length.value).decode()
    finally:
        library.SecKeychainItemFreeContent(None, data)


def _set_here(service: str, account: str, password: str) -> None:
    """Store or replace the secret."""
    library = _load()
    secret = password.encode()
    status = library.SecKeychainAddGenericPassword(
        None,
        len(service), service.encode(),
        len(account), account.encode(),
        len(secret), secret, None,
    )
    if status == _ERR_DUPLICATE_ITEM:
        # Already there: look the item up and overwrite its data.
        item = ctypes.c_void_p()
        status = library.SecKeychainFindGenericPassword(
            None,
            len(service), service.encode(),
            len(account), account.encode(),
            None, None, ctypes.byref(item),
        )
        if status != 0:
            raise _fail(status, "replacing the connection token")
        try:
            status = library.SecKeychainItemModifyAttributesAndData(
                item, None, len(secret), secret
            )
        finally:
            library.CFRelease(item)
    if status != 0:
        raise _fail(status, "saving the connection token")


def _delete_here(service: str, account: str) -> bool:
    """Remove the secret. True when something was removed."""
    library = _load()
    item = ctypes.c_void_p()
    status = library.SecKeychainFindGenericPassword(
        None,
        len(service), service.encode(),
        len(account), account.encode(),
        None, None, ctypes.byref(item),
    )
    if status == _ERR_ITEM_NOT_FOUND:
        return False
    if status != 0:
        raise _fail(status, "locating the connection token")
    try:
        status = library.SecKeychainItemDelete(item)
    finally:
        library.CFRelease(item)
    if status != 0:
        raise _fail(status, "removing the connection token")
    return True


# ------------------------------------------------------------ the helper

HELPER_NAME = "keychain-helper"
HELPER_FLAG = "--keychain-helper"
HELPER_TIMEOUT_SECONDS = 120.0


def support_dir() -> Path:
    override = os.environ.get("DATALINK_KEYCHAIN_HELPER_DIR")
    if override:
        return Path(override).expanduser()
    if _paths is not None:
        return _paths.APP_SUPPORT_DIR / "runtime"
    return Path.home() / "Library" / "Application Support" / "DataLink Scanner" / "runtime"


def helper_path() -> Path:
    return support_dir() / HELPER_NAME


def _interpreter() -> Path | None:
    """The interpreter to copy, when there is a sensible one to copy.

    A PyInstaller build's sys.executable is the app itself; copying that would
    start a second app rather than run a script. Such a build also lives at a
    path the user chose and does not move, so it has no problem to solve.
    """
    if getattr(sys, "frozen", False):
        return None
    # A framework build's bin/python3.x is a stub that re-execs the real binary
    # inside Python.app, and it is the re-exec the Keychain records — so
    # copying the stub would leave the trust pointing back at the versioned
    # framework. Copy what actually ends up running.
    inner = (
        Path(sys.base_prefix)
        / "Resources" / "Python.app" / "Contents" / "MacOS" / "Python"
    )
    if inner.is_file():
        return inner
    candidate = Path(sys.executable).resolve()
    return candidate if candidate.is_file() else None


def ensure_helper() -> Path | None:
    """Put the interpreter at the fixed path, and keep it current.

    Copied rather than symlinked: a symlink resolves to the versioned original
    and the recorded path would move again with the next upgrade.
    """
    source = _interpreter()
    if source is None:
        return None
    destination = helper_path()
    # Re-signing changes the bytes, so the copy never matches its source and
    # comparing the two directly would rebuild the helper on every call — and
    # every rebuild is another file for the Keychain to be unsure about. The
    # digest of what it was made from is what decides.
    stamp = destination.with_name(destination.name + ".source")
    try:
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
    except OSError:
        return None
    try:
        if destination.is_file() and stamp.is_file():
            if stamp.read_text().strip() == digest:
                return destination
        destination.parent.mkdir(parents=True, exist_ok=True)
        # Replaced through a temporary name so a half-written helper is never
        # left behind for the next launch to run.
        staged = destination.with_suffix(".new")
        shutil.copy2(source, staged)
        staged.chmod(0o755)
        _resign(staged)
        staged.replace(destination)
        stamp.write_text(digest)
        return destination
    except OSError:
        return None


def _resign(binary: Path) -> None:
    """Give the copy its own ad-hoc signature.

    A signature covers the bundle a binary came from, so the copy carries one
    that no longer verifies, and macOS then refuses to record it as a trusted
    application at all (-67030). Re-signing in place is what makes the copy a
    thing the Keychain can name.
    """
    try:
        subprocess.run(
            ["/usr/bin/codesign", "--force", "--sign", "-", str(binary)],
            capture_output=True,
            timeout=120,
        )
    except (OSError, subprocess.SubprocessError):
        # Without a valid signature the helper cannot be trusted, and the
        # caller falls back to asking in-process.
        pass


def _ask_helper(request: dict) -> dict | None:
    """Run one Keychain operation in the helper. None when it cannot be used."""
    if os.environ.get("DATALINK_KEYCHAIN_NO_HELPER"):
        return None
    helper = ensure_helper()
    if helper is None:
        return None
    try:
        finished = subprocess.run(
            [str(helper), str(Path(__file__).resolve()), HELPER_FLAG],
            # The secret goes down stdin, so it never appears in `ps`.
            input=json.dumps(request),
            capture_output=True,
            text=True,
            timeout=HELPER_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if finished.returncode != 0 or not finished.stdout.strip():
        return None
    try:
        return json.loads(finished.stdout)
    except ValueError:
        return None


def _through_helper(action: str, service: str, account: str, password: str = ""):
    reply = _ask_helper(
        {"action": action, "service": service, "account": account, "password": password}
    )
    if reply is None:
        return None, False
    if reply.get("error"):
        raise KeychainError(str(reply["error"]))
    return reply.get("value"), True


def get_password(service: str, account: str) -> str | None:
    value, answered = _through_helper("get", service, account)
    return value if answered else _get_here(service, account)


def set_password(service: str, account: str, password: str) -> None:
    _, answered = _through_helper("set", service, account, password)
    if not answered:
        _set_here(service, account, password)


def delete_password(service: str, account: str) -> bool:
    value, answered = _through_helper("delete", service, account)
    return bool(value) if answered else _delete_here(service, account)


def _serve() -> int:
    """Helper mode: one request in on stdin, one answer out on stdout."""
    try:
        request = json.loads(sys.stdin.read() or "{}")
        action = request.get("action")
        service = str(request.get("service") or "")
        account = str(request.get("account") or "")
        if action == "get":
            answer = {"value": _get_here(service, account)}
        elif action == "set":
            _set_here(service, account, str(request.get("password") or ""))
            answer = {"value": True}
        elif action == "delete":
            answer = {"value": _delete_here(service, account)}
        else:
            answer = {"error": f"Unknown request {action!r}"}
    except KeychainError as exc:
        answer = {"error": str(exc)}
    except Exception as exc:  # the caller falls back rather than crashing
        answer = {"error": f"{type(exc).__name__}: {exc}"}
    sys.stdout.write(json.dumps(answer))
    return 0


if __name__ == "__main__":
    if HELPER_FLAG in sys.argv:
        raise SystemExit(_serve())
    raise SystemExit("This module is not meant to be run directly.")

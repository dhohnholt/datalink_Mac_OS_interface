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

The frozen .app has the same problem for a different reason — it is re-signed
on every build and replaced wholesale by every update — and no interpreter to
copy, because the Python inside it is a shared library rather than an
executable. It carries a 51 KB compiled helper instead, built from
``packaging/keychain_helper.c``, which is copied to the same fixed directory
under its own name. Both can be installed on one Mac without disturbing each
other's trust.
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
    from . import edition as _edition
except ImportError:  # pragma: no cover - only in helper mode
    _paths = None
    _edition = None


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
# The frozen .app has no interpreter to copy — the Python inside it is a
# shared library, not an executable — so it carries a small compiled helper
# instead. It gets its own name: a Mac with both builds installed would
# otherwise have them overwrite each other's copy at the shared path, and
# every overwrite is another password prompt.
NATIVE_HELPER_NAME = "keychain-helper-native"
HELPER_FLAG = "--keychain-helper"
HELPER_TIMEOUT_SECONDS = 120.0


def support_dir() -> Path:
    override = os.environ.get("DATALINK_KEYCHAIN_HELPER_DIR")
    if override:
        return Path(override).expanduser()
    if _paths is not None:
        return _paths.APP_SUPPORT_DIR / "runtime"
    return Path.home() / "Library" / "Application Support" / "DataLink Scanner" / "runtime"


def helper_path(kind: str = "python") -> Path:
    return support_dir() / (NATIVE_HELPER_NAME if kind == "native" else HELPER_NAME)


def _bundled_native_helper() -> Path | None:
    """The compiled helper the frozen .app carries, in Contents/Helpers."""
    if not getattr(sys, "frozen", False):
        return None
    bundled = (
        Path(sys.executable).resolve().parent.parent / "Helpers" / HELPER_NAME
    )
    return bundled if bundled.is_file() else None


def _helper_source() -> tuple[Path | None, str]:
    """What to copy to the fixed path, and which kind of helper it is.

    A frozen build carries a compiled one; everything else copies the running
    interpreter. Both end up as a small binary at a path that survives
    updates, which is the only thing the Keychain cares about.
    """
    if getattr(sys, "frozen", False):
        return _bundled_native_helper(), "native"
    return _interpreter(), "python"


def _interpreter() -> Path | None:
    """The interpreter to copy, when there is a sensible one to copy.

    A PyInstaller build's sys.executable is the app itself; copying that would
    start a second app rather than run a script, so a frozen build uses the
    compiled helper from its own bundle instead — see _helper_source.
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


def ensure_helper(rebuild: bool = False) -> Path | None:
    """Put an interpreter at the fixed path, and then leave it alone.

    Copied rather than symlinked: a symlink resolves to the versioned original
    and the recorded path would move again with the next upgrade.

    Replacing it is what costs a password prompt, because the Keychain records
    the exact binary it trusts. So an existing helper is kept even when the
    interpreter it was copied from has changed — a Python upgrade, or the app
    being run from a different environment, is no reason to ask the teacher for
    their password again. `rebuild` is for the one case that matters: the
    helper stopped working, which _ask_helper notices by trying to use it.
    """
    source, kind = _helper_source()
    if source is None:
        return None
    destination = helper_path(kind)
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
        if destination.is_file() and not rebuild:
            # A different interpreter asking is not a reason to replace it;
            # record what we compared against so the next call is a cheap
            # string comparison rather than another digest.
            if not stamp.is_file() or stamp.read_text().strip() != digest:
                stamp.write_text(digest)
            return destination
        destination.parent.mkdir(parents=True, exist_ok=True)
        # Replaced through a temporary name so a half-written helper is never
        # left behind for the next launch to run.
        staged = destination.with_suffix(".new")
        shutil.copy2(source, staged)
        staged.chmod(0o755)
        # Order matters: rewriting the load command invalidates any signature,
        # so it happens before signing, not after. The compiled helper links
        # only against system frameworks, so it has nothing to repoint.
        if kind == "python":
            _pin_to_stable_framework(staged)
        _resign(staged)
        staged.replace(destination)
        stamp.write_text(digest)
        return destination
    except OSError:
        return None


def _pin_to_stable_framework(binary: Path) -> None:
    """Point the copy at Homebrew's opt path instead of a Cellar version.

    The interpreter links against its framework by absolute path, and for a
    Homebrew Python that path carries the version:

        /opt/homebrew/Cellar/python@3.13/3.13.15/Frameworks/.../Python

    So the next Python patch release deletes it and the helper dies at launch
    with "Library missing" — after which every call quietly falls back to
    asking in-process, which is a password prompt each time. The opt path is
    the same file through a symlink Homebrew repoints on upgrade, which is the
    whole reason the app bundle uses it too.
    """
    try:
        listed = subprocess.run(
            ["/usr/bin/otool", "-L", str(binary)],
            capture_output=True, text=True, timeout=60,
        )
    except (OSError, subprocess.SubprocessError):
        return
    for line in (listed.stdout or "").splitlines():
        linked = line.strip().split(" (")[0]
        if "/Cellar/" not in linked or not linked.endswith("/Python"):
            continue
        parts = Path(linked).parts
        index = parts.index("Cellar")
        # .../Cellar/<formula>/<version>/rest → .../opt/<formula>/rest
        stable = Path(*parts[:index], "opt", parts[index + 1], *parts[index + 3:])
        if not stable.is_file():
            continue
        try:
            subprocess.run(
                ["/usr/bin/install_name_tool", "-change", linked, str(stable), str(binary)],
                capture_output=True, timeout=60,
            )
        except (OSError, subprocess.SubprocessError):
            return


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
    # A helper that has stopped working — a deleted framework, a truncated
    # copy — would otherwise send every call back to asking in-process, which
    # is a password prompt each time. Trying it is how that gets noticed, so a
    # failure earns exactly one rebuild and one retry.
    native = getattr(sys, "frozen", False)
    for rebuild in (False, True):
        helper = ensure_helper(rebuild=rebuild)
        if helper is None:
            return None
        # A compiled helper cannot import this module, so it speaks a plain
        # line protocol instead of JSON. Either way the secret goes down
        # stdin and never appears in `ps`.
        command = (
            [str(helper)] if native
            else [str(helper), str(Path(__file__).resolve()), HELPER_FLAG]
        )
        payload = (
            "\n".join([
                str(request.get("action") or ""),
                str(request.get("service") or ""),
                str(request.get("account") or ""),
            ]) + "\n" + str(request.get("password") or "")
            if native else json.dumps(request)
        )
        try:
            finished = subprocess.run(
                command,
                input=payload,
                capture_output=True,
                text=True,
                timeout=HELPER_TIMEOUT_SECONDS,
            )
        except (OSError, subprocess.SubprocessError):
            continue
        if not native and finished.returncode != 0:
            continue
        if not finished.stdout:
            continue
        if native:
            answer = _read_native_reply(
                finished.stdout, str(request.get("action") or "")
            )
            if answer is None:
                continue
            return answer
        try:
            return json.loads(finished.stdout)
        except ValueError:
            return None
    return None


def _read_native_reply(output: str, action: str) -> dict | None:
    """Turn the compiled helper's answer into the shape callers expect.

    "ok" means different things depending on what was asked: the stored value
    for a read, and simply "done" for a write or a delete. Reading a token
    that happens to be empty must not come back as True.
    """
    status, _, body = output.partition("\n")
    status = status.strip()
    if status == "ok":
        return {"value": body if action == "get" else True}
    if status == "none":
        # Nothing stored, or nothing to delete.
        return {"value": None if action == "get" else False}
    if status == "err":
        return {"error": body.strip() or "The Keychain refused the request"}
    return None


def _through_helper(action: str, service: str, account: str, password: str = ""):
    # The helper exists because an ad-hoc signed app is identified to the
    # Keychain by its path and its bytes, so every rebuild looks like a
    # different application and the ACL asks again. A store build is signed by
    # one stable identity, which is the thing the helper works around, and
    # writing an executable out and running it is forbidden in the sandbox
    # regardless. Reporting "not answered" sends every caller down the
    # in-process path, which is what the helper was standing in for.
    if _edition is not None and _edition.sandboxed():
        return None, False
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

"""macOS Keychain storage for the T-TESS connection token.

The token is a credential: it goes in the Keychain and nowhere else — not in
the database beside the scans, not in a preferences file, not in a log line.

Calls go through Security.framework directly rather than the `security`
command, because that command takes the password as an argument and would put
the token in the process list for as long as it runs.
"""

from __future__ import annotations

import ctypes
import ctypes.util


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


def get_password(service: str, account: str) -> str | None:
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


def set_password(service: str, account: str, password: str) -> None:
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


def delete_password(service: str, account: str) -> bool:
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

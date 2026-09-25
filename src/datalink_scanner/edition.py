"""Which edition of the app this is, answered at runtime.

One codebase ships twice: a Developer ID disk image that may do as it likes,
and a Mac App Store build that lives inside the sandbox. Several things the
app does are forbidden in the second one, so each of them asks here first.

This is detected rather than compiled in, because a build flag can be wrong
and this cannot.
"""

from __future__ import annotations

from pathlib import Path

CONTAINER_MARKER = "/Library/Containers/"


def sandboxed() -> bool:
    """True inside the App Store build.

    The sandbox relocates the home directory into the app's container. Note
    what it does *not* do: it leaves the HOME environment variable pointing at
    the real home, so `os.environ["HOME"]` escapes the container and then gets
    denied. Only ask through pwd, which is what Path.home() does and what the
    sandbox actually redirects.

    Verified on a signed sandboxed build, 2026-09-25:

        Path.home()      -> ~/Library/Containers/org.davidhohnholt.datalink-scanner/Data
        os.environ[HOME] -> /Users/davidhohnholt

    APP_SANDBOX_CONTAINER_ID is not set in this bundle, so it is no use as an
    alternative signal.
    """
    return CONTAINER_MARKER in str(Path.home())

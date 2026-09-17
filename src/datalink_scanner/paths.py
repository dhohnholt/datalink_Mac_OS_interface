"""Where the app finds its web assets and writes captured sessions.

Three deployments have to work:

* a source checkout (``pip install -e .``) — sessions stay in ``captures/``
  next to the code, which is what the protocol-discovery workflow expects
* a Homebrew virtualenv — sessions go to Application Support
* a PyInstaller ``.app`` — web assets come from ``Contents/Resources``
"""

from __future__ import annotations

import os
import sys
from pathlib import Path


APP_SUPPORT_DIR = Path.home() / "Library" / "Application Support" / "DataLink Scanner"


def is_frozen() -> bool:
    """True when running from a PyInstaller bundle."""
    return bool(getattr(sys, "frozen", False))


def web_root() -> Path:
    """Directory holding index.html, styles.css and app.js."""
    if is_frozen():
        # Contents/MacOS/<executable> → Contents/Resources/web
        return Path(sys.executable).resolve().parent.parent / "Resources" / "web"
    return Path(__file__).resolve().parent / "webui"


def source_checkout_root() -> Path | None:
    """Repository root when running from a checkout, otherwise None."""
    if is_frozen():
        return None
    # src/datalink_scanner/paths.py → <root>
    root = Path(__file__).resolve().parents[2]
    return root if (root / "pyproject.toml").is_file() else None


def capture_root(override: str | os.PathLike[str] | None = None) -> Path:
    """Directory that receives ``browser_session_*.jsonl`` files.

    ``--capture-dir`` wins, then ``DATALINK_CAPTURE_DIR``, then the
    deployment default.
    """
    if override:
        return Path(override).expanduser().resolve()
    from_env = os.environ.get("DATALINK_CAPTURE_DIR")
    if from_env:
        return Path(from_env).expanduser().resolve()
    checkout = source_checkout_root()
    if checkout is not None:
        return checkout / "captures"
    return APP_SUPPORT_DIR / "captures"


def database_path(override: str | os.PathLike[str] | None = None) -> Path:
    """The SQLite file, kept beside the saved sessions so that --capture-dir
    isolates the whole data set."""
    return capture_root(override) / "library.sqlite3"

"""PyInstaller entry point for the standalone .app / .dmg build.

PyInstaller runs its entry script as ``__main__``, so the package's own
``__main__.py`` (which uses a relative import) cannot be used directly.
"""

import sys

from datalink_scanner import paper
from datalink_scanner.cli import main

# Reading a paper batch needs a Python to run the sheet reader in, and a frozen
# app has none: it re-runs itself behind this flag. Checked before anything
# else, because otherwise the argument is ignored and a second window opens.
if len(sys.argv) > 1 and sys.argv[1] == paper.RUN_FLAG:
    raise SystemExit(paper.run_pipeline(sys.argv[2:]))

# Otherwise ignore argv: LaunchServices can append arguments such as
# -psn_0_12345.
raise SystemExit(main([]))

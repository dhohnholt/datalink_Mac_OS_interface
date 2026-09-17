"""PyInstaller entry point for the standalone .app / .dmg build.

PyInstaller runs its entry script as ``__main__``, so the package's own
``__main__.py`` (which uses a relative import) cannot be used directly.
"""

from datalink_scanner.cli import main

# Ignore argv: LaunchServices can append arguments such as -psn_0_12345.
raise SystemExit(main([]))

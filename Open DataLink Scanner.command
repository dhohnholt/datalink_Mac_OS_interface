#!/bin/zsh
# Double-clickable launcher for a source checkout.
# Installed copies should use the `datalink-scanner` command instead.
set -e
SCRIPT_DIR=${0:A:h}
cd "$SCRIPT_DIR"
if [[ -x .venv/bin/datalink-scanner ]]; then
  exec .venv/bin/datalink-scanner serve
fi
echo "The project virtual environment was not set up."
echo "From $SCRIPT_DIR run:"
echo "    python3 -m venv .venv && .venv/bin/pip install -e ."
read "?Press Return to close."
exit 1

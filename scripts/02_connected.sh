#!/bin/bash
# Phase 1, Step 2 — Run this AFTER plugging in the DataLink 1200 and
# waiting ~10 seconds for macOS to enumerate it.
# Captures a "with scanner" snapshot and diffs it against the baseline.

set -euo pipefail

OUTDIR="$HOME/Desktop/datalink-captures"
mkdir -p "$OUTDIR"
BASELINE="$OUTDIR/baseline.txt"
OUT="$OUTDIR/connected.txt"
DIFFOUT="$OUTDIR/diff.txt"

if [ ! -f "$BASELINE" ]; then
  echo "ERROR: $BASELINE not found. Run 01_baseline_unplugged.sh first (scanner unplugged)."
  exit 1
fi

echo "Writing connected snapshot to $OUT"
echo

{
  echo "=== Timestamp ==="
  date

  echo
  echo "=== USB Devices (connected) ==="
  system_profiler SPUSBDataType

  echo
  echo "=== /dev/cu.* (connected) ==="
  ls -la /dev/cu.* 2>&1 || true

  echo
  echo "=== /dev/tty.* (connected) ==="
  ls -la /dev/tty.* 2>&1 || true

  echo
  echo "=== IOKit USB tree (connected) ==="
  ioreg -p IOUSB -l -w 0

} > "$OUT"

diff "$BASELINE" "$OUT" > "$DIFFOUT" || true

echo "Done."
echo "Connected snapshot: $OUT"
echo "Diff vs baseline:   $DIFFOUT"
echo
echo "----- DIFF OUTPUT -----"
cat "$DIFFOUT"
echo "------------------------"
echo
echo "Paste the contents of diff.txt back to Claude for analysis."

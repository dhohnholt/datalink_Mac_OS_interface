#!/bin/bash
# Phase 1, Step 1 — Run this with the DataLink 1200 UNPLUGGED.
# Captures a clean "before" snapshot of USB/serial devices so we can
# diff against it once the scanner is connected.

set -euo pipefail

OUTDIR="$HOME/Desktop/datalink-captures"
mkdir -p "$OUTDIR"
OUT="$OUTDIR/baseline.txt"

echo "Writing baseline to $OUT"
echo "Make sure the DataLink 1200 is UNPLUGGED before running this."
echo

{
  echo "=== Timestamp ==="
  date

  echo
  echo "=== USB Devices (baseline) ==="
  system_profiler SPUSBDataType

  echo
  echo "=== /dev/cu.* (baseline) ==="
  ls -la /dev/cu.* 2>&1 || true

  echo
  echo "=== /dev/tty.* (baseline) ==="
  ls -la /dev/tty.* 2>&1 || true

  echo
  echo "=== IOKit USB tree (baseline) ==="
  ioreg -p IOUSB -l -w 0

} > "$OUT"

echo "Done. Baseline saved to: $OUT"
echo "Next: plug in the DataLink 1200, wait ~10 seconds, then run 02_connected.sh"

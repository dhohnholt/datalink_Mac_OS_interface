#!/usr/bin/env python3
"""Run labeled, one-sheet-at-a-time DataLink 1200 capture trials.

The tool never writes data bytes to the scanner. It asserts DTR/RTS, records
all received bytes with monotonic timestamps, and separates a trial only after
the line has been quiet for a configurable interval. Packet length is not
assumed.
"""

import argparse
import csv
import datetime
import json
import os
import sys
import time

try:
    import serial
except ImportError:
    print("pyserial is not installed. Run: pip3 install -r scripts/requirements.txt")
    sys.exit(1)


def read_until_quiet(ser, first_byte_timeout, quiet_seconds):
    """Return timestamped bytes after waiting for activity, then line silence."""
    started = time.monotonic()
    last_byte_at = None
    events = []

    while True:
        now = time.monotonic()
        waiting = ser.in_waiting
        data = ser.read(waiting or 1)
        received_at = time.monotonic()
        if data:
            for value in data:
                events.append((received_at - started, value))
            last_byte_at = received_at
        elif last_byte_at is None and now - started >= first_byte_timeout:
            return events
        elif last_byte_at is not None and now - last_byte_at >= quiet_seconds:
            return events
        else:
            time.sleep(0.01)


def main():
    parser = argparse.ArgumentParser(
        description="Labeled, read-only capture trials for the DataLink 1200."
    )
    parser.add_argument("--port", default="/dev/cu.usbserial-1200")
    parser.add_argument("--baud", type=int, default=9600)
    parser.add_argument("--trials", type=int, default=1)
    parser.add_argument("--label", required=True, help="Experiment name")
    parser.add_argument("--student-id", default="")
    parser.add_argument("--score", type=int)
    parser.add_argument("--first-byte-timeout", type=float, default=20.0)
    parser.add_argument("--quiet-seconds", type=float, default=0.5)
    parser.add_argument("--outdir", default="captures")
    args = parser.parse_args()

    stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    run_dir = os.path.join(args.outdir, f"controlled_{args.label}_{stamp}")
    os.makedirs(run_dir, exist_ok=False)
    manifest_path = os.path.join(run_dir, "trials.csv")

    settings = {
        "port": args.port,
        "baud": args.baud,
        "bytesize": 8,
        "parity": "N",
        "stopbits": 1,
        "dtr_rts_asserted": True,
        "first_byte_timeout": args.first_byte_timeout,
        "quiet_seconds": args.quiet_seconds,
        "student_id": args.student_id,
        "known_score": args.score,
    }
    with open(os.path.join(run_dir, "settings.json"), "w") as handle:
        json.dump(settings, handle, indent=2)
        handle.write("\n")

    print(f"Saving controlled capture to {run_dir}")
    print("No data bytes will be sent; DTR and RTS will be asserted.")

    with serial.Serial(
        port=args.port,
        baudrate=args.baud,
        bytesize=8,
        parity=serial.PARITY_NONE,
        stopbits=serial.STOPBITS_ONE,
        timeout=0.05,
    ) as ser, open(manifest_path, "w", newline="") as manifest:
        ser.dtr = True
        ser.rts = True
        writer = csv.DictWriter(
            manifest,
            fieldnames=["trial", "student_id", "known_score", "byte_count", "hex"],
        )
        writer.writeheader()

        for trial in range(1, args.trials + 1):
            input(f"\nTrial {trial}/{args.trials}: press Enter, then feed the sheet... ")
            # Clear only after Enter. Bytes can arrive while the operator is
            # reading the prompt; treating them as the next trial would assign
            # stale/delayed traffic to the wrong sheet.
            pending = ser.read(ser.in_waiting)
            if pending:
                print(f"Pre-trial unsolicited bytes: {pending.hex(' ')}")

            events = read_until_quiet(
                ser, args.first_byte_timeout, args.quiet_seconds
            )
            payload = bytes(value for _, value in events)
            event_path = os.path.join(run_dir, f"trial_{trial:02d}_events.csv")
            with open(event_path, "w", newline="") as event_file:
                event_writer = csv.writer(event_file)
                event_writer.writerow(["seconds_from_trial_start", "byte_hex"])
                for offset, value in events:
                    event_writer.writerow([f"{offset:.6f}", f"{value:02x}"])
            with open(os.path.join(run_dir, f"trial_{trial:02d}.bin"), "wb") as raw:
                raw.write(payload)

            writer.writerow(
                {
                    "trial": trial,
                    "student_id": args.student_id,
                    "known_score": "" if args.score is None else args.score,
                    "byte_count": len(payload),
                    "hex": payload.hex(" "),
                }
            )
            manifest.flush()
            print(f"Captured {len(payload)} bytes: {payload.hex(' ') or '(timeout)'}")

    print(f"\nFinished. Trial manifest: {manifest_path}")


if __name__ == "__main__":
    main()

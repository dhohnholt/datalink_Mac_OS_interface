#!/usr/bin/env python3
"""
serial_sniffer.py — READ-ONLY serial sniffer for the Apperson DataLink 1200.

CONFIRMED (2026): this scanner (Silicon Labs CP210x, VID:PID 10c4:ea60)
requires DTR and RTS asserted before it transmits anything. Without this,
every baud rate scan returns 0 bytes even while sheets are actively fed
through the scanner. This script asserts both by default.

This script NEVER writes data bytes to the serial port -- DTR/RTS are
modem control lines (signaling "ready"), not data transmission, so this
remains a read-only capture tool in spirit.

USAGE

  Basic capture (Ctrl+C to stop):
    python3 serial_sniffer.py --port /dev/cu.usbserial-1200 --baud 9600 \\
        --label test_a_1A_2B_3C_4D_5E

  Longer listen, in case data trickles in after an initial handshake:
    python3 serial_sniffer.py --port /dev/cu.usbserial-1200 --baud 9600 \\
        --label heartbeat_check --duration 60

OUTPUT

  Labeled captures land in captures/<label>_<timestamp>/:
    raw.bin        - exact raw bytes received
    hexdump.txt     - timestamped hex + ASCII view
    meta.txt        - port/baud/settings and byte count

Requires: pyserial (pip3 install pyserial)
"""

import argparse
import datetime
import os
import sys
import time


def _require_serial():
    """Import pyserial lazily so the formatting helpers stay unit-testable."""
    try:
        import serial
    except ImportError:
        print("pyserial is not installed. Run:")
        print("    pip3 install pyserial")
        sys.exit(1)
    return serial


def hex_ascii_line(offset, chunk):
    hex_part = " ".join(f"{b:02x}" for b in chunk)
    hex_part = hex_part.ljust(16 * 3 - 1)
    ascii_part = "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)
    return f"{offset:08x}  {hex_part}  |{ascii_part}|"


def format_hexdump(data, base_offset=0):
    lines = []
    for i in range(0, len(data), 16):
        chunk = data[i : i + 16]
        lines.append(hex_ascii_line(base_offset + i, chunk))
    return "\n".join(lines)


def open_port(port, baud, timeout, assert_dtr_rts=True):
    serial = _require_serial()
    ser = serial.Serial(
        port=port,
        baudrate=baud,
        bytesize=8,
        parity=serial.PARITY_NONE,
        stopbits=serial.STOPBITS_ONE,
        timeout=timeout,
    )
    if assert_dtr_rts:
        ser.dtr = True
        ser.rts = True
    return ser


def capture(args):
    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    label = args.label or "capture"
    outdir = os.path.join(args.outdir, f"{label}_{timestamp}")
    os.makedirs(outdir, exist_ok=True)

    raw_path = os.path.join(outdir, "raw.bin")
    hexdump_path = os.path.join(outdir, "hexdump.txt")
    meta_path = os.path.join(outdir, "meta.txt")

    print(f"Opening {args.port} @ {args.baud} baud, DTR/RTS asserted")
    print("READ-ONLY mode — this script never transmits data to the device.")
    print(f"Output directory: {outdir}")
    if args.duration:
        print(f"Listening for {args.duration}s. Feed a sheet through now.")
    else:
        print("Listening. Feed a sheet through, then press Ctrl+C to stop.")
    print()

    serial = _require_serial()
    all_bytes = bytearray()
    start_time = datetime.datetime.now()
    end_at = time.time() + args.duration if args.duration else None

    try:
        with open_port(args.port, args.baud, args.timeout) as ser, open(
            raw_path, "wb"
        ) as raw_f, open(hexdump_path, "w") as hex_f:

            while True:
                if end_at and time.time() >= end_at:
                    break
                chunk = ser.read(ser.in_waiting or 1)
                if chunk:
                    now = datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3]
                    offset = len(all_bytes)
                    all_bytes.extend(chunk)

                    raw_f.write(chunk)
                    raw_f.flush()

                    dump = format_hexdump(chunk, base_offset=offset)
                    header = (
                        f"\n--- {now}  (+{len(chunk)} bytes, offset {offset}) ---\n"
                    )
                    hex_f.write(header + dump + "\n")
                    hex_f.flush()

                    print(header.strip())
                    print(dump)
                else:
                    time.sleep(0.02)

    except KeyboardInterrupt:
        print("\nStopped by user.")
    except serial.SerialException as e:
        print(f"\nSerial error: {e}")
    finally:
        end_time = datetime.datetime.now()
        with open(meta_path, "w") as meta_f:
            meta_f.write(f"port: {args.port}\n")
            meta_f.write(f"baud: {args.baud}\n")
            meta_f.write("bytesize: 8\nparity: N\nstopbits: 1\n")
            meta_f.write("dtr_rts_asserted: True\n")
            meta_f.write(f"start: {start_time.isoformat()}\n")
            meta_f.write(f"end: {end_time.isoformat()}\n")
            meta_f.write(f"total_bytes: {len(all_bytes)}\n")

        print(f"\nCaptured {len(all_bytes)} bytes.")
        print(f"Raw bytes:  {raw_path}")
        print(f"Hex dump:   {hexdump_path}")
        print(f"Metadata:   {meta_path}")


def main():
    parser = argparse.ArgumentParser(
        description="Read-only serial sniffer for the DataLink 1200."
    )
    parser.add_argument("--port", required=True)
    parser.add_argument("--baud", type=int, default=9600)
    parser.add_argument("--timeout", type=float, default=0.5)
    parser.add_argument("--label", default=None)
    parser.add_argument("--outdir", default="captures")
    parser.add_argument(
        "--duration",
        type=float,
        default=None,
        help="Seconds to listen. Omit to listen until Ctrl+C.",
    )
    args = parser.parse_args()
    capture(args)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
list_serial_ports.py — Enumerate serial ports macOS currently sees.

Run this with the scanner UNPLUGGED, then again with it PLUGGED IN,
and compare. Whatever new entry shows up is (probably) the scanner.

Usage:
    python3 list_serial_ports.py

Requires: pyserial (pip3 install pyserial)
"""

import sys

try:
    from serial.tools import list_ports
except ImportError:
    print("pyserial is not installed. Run:")
    print("    pip3 install pyserial")
    sys.exit(1)


def main():
    ports = list(list_ports.comports())

    if not ports:
        print("No serial ports found.")
        return

    print(f"Found {len(ports)} serial port(s):\n")
    for p in ports:
        print(f"Device:       {p.device}")
        print(f"  Name:       {p.name}")
        print(f"  Description:{p.description}")
        print(f"  HWID:       {p.hwid}")
        print(f"  VID:PID:    {p.vid:04x}:{p.pid:04x}" if p.vid and p.pid else "  VID:PID:    (none)")
        print(f"  Manufacturer: {p.manufacturer}")
        print(f"  Product:    {p.product}")
        print(f"  Serial #:   {p.serial_number}")
        print()


if __name__ == "__main__":
    main()

"""Formatting tests for the read-only discovery sniffer."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

import serial_sniffer  # noqa: E402


class HexdumpTests(unittest.TestCase):
    def test_line_layout(self):
        line = serial_sniffer.hex_ascii_line(0, b"DataLink")
        self.assertTrue(line.startswith("00000000  "))
        self.assertTrue(line.endswith("|DataLink|"))

    def test_non_printable_bytes_become_dots(self):
        self.assertTrue(serial_sniffer.hex_ascii_line(0, b"\x00\x1f\x7f").endswith("|...|"))

    def test_wraps_every_sixteen_bytes(self):
        dump = serial_sniffer.format_hexdump(bytes(range(32)))
        self.assertEqual(len(dump.split("\n")), 2)

    def test_offsets_continue_from_the_base(self):
        dump = serial_sniffer.format_hexdump(bytes(16), base_offset=0x100)
        self.assertTrue(dump.startswith("00000100  "))

    def test_short_final_line_stays_aligned(self):
        lines = serial_sniffer.format_hexdump(bytes(20)).split("\n")
        self.assertEqual(lines[0].index("|"), lines[1].index("|"))

    def test_empty_input(self):
        self.assertEqual(serial_sniffer.format_hexdump(b""), "")


if __name__ == "__main__":
    unittest.main()

"""A macOS interface for the Apperson DataLink 1200 optical mark scanner.

The package is split so that nothing above the transport layer needs a
physical scanner:

``interface``  serial transport plus the raw-byte → :class:`DataLinkFormRecord`
               parser recovered from USBPcap traces of DataLink Connect 4.5
``server``     the local-only HTTP workspace the browser UI talks to
``paths``      where web assets live and where sessions are written
``cli``        the ``datalink-scanner`` command
"""

__version__ = "1.4.0"

__all__ = ["__version__"]

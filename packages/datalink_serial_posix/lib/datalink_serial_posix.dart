/// macOS serial access for the DataLink 1200, through libc.
library;

export 'src/posix_serial.dart'
    show PosixSerialConnection, PosixSerialTransport, defaultSerialTransport;

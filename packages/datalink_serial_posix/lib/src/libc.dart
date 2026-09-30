/// The handful of libc calls serial access needs, and the Darwin constants
/// that go with them. Everything here is macOS-specific on purpose: the values
/// are not the same on Linux.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

final DynamicLibrary _libc = DynamicLibrary.process();

// ---------------------------------------------------------------- open flags

const int oRdwr = 0x0002;
const int oNonblock = 0x0004;
const int oNoctty = 0x20000;
const int oCloexec = 0x01000000;

// -------------------------------------------------------------- termios bits

const int igNbrk = 0x00000001;
const int parmrk = 0x00000008;
const int inpck = 0x00000010;
const int istrip = 0x00000020;
const int inlcr = 0x00000040;
const int igncr = 0x00000080;
const int icrnl = 0x00000100;
const int ixon = 0x00000200;
const int ixoff = 0x00000400;
const int ixany = 0x00000800;

const int opost = 0x00000001;
const int onlcr = 0x00000002;
const int ocrnl = 0x00000010;

const int csize = 0x00000300;
const int cs8 = 0x00000300;
const int cstopb = 0x00000400;
const int cread = 0x00000800;
const int parenb = 0x00001000;
const int parodd = 0x00002000;
const int clocal = 0x00008000;
const int crtscts = 0x00030000;

const int echoke = 0x00000001;
const int echoe = 0x00000002;
const int echok = 0x00000004;
const int echo = 0x00000008;
const int echonl = 0x00000010;
const int echoprt = 0x00000020;
const int echoctl = 0x00000040;
const int isig = 0x00000080;
const int icanon = 0x00000100;
const int iexten = 0x00000400;

const int vmin = 16;
const int vtime = 17;

const int tcsanow = 0;
const int tciflush = 1;

// ------------------------------------------------------------------- ioctls

const int tiocmget = 0x4004746a;
const int tiocmbic = 0x8004746b;
const int tiocmbis = 0x8004746c;
const int tiocexcl = 0x2000740d;
const int tiocnxcl = 0x2000740e;
const int fionread = 0x4004667f;
const int tiocoutq = 0x40047473;

const int tiocmDtr = 0x00000002;
const int tiocmRts = 0x00000004;

// -------------------------------------------------------------------- errno

const int eintr = 4;
const int eio = 5;
const int eacces = 13;
const int ebusy = 16;
const int enoent = 2;
const int eperm = 1;
const int eagain = 35;
const int enotty = 25;

const int lockEx = 0x02;
const int lockNb = 0x04;
const int lockUn = 0x08;

// --------------------------------------------------------- struct termios

/// `struct termios` on 64-bit Darwin: four 8-byte flag words, twenty control
/// characters, four bytes of padding, then two 8-byte speeds.
const int termiosSize = 72;
const int _iflagAt = 0;
const int _oflagAt = 8;
const int _cflagAt = 16;
const int _lflagAt = 24;
const int _ccAt = 32;
const int _ispeedAt = 56;
const int _ospeedAt = 64;

/// A heap `struct termios` with named access to the fields pyserial touches.
final class Termios {
  Termios() : pointer = calloc<Uint8>(termiosSize);

  final Pointer<Uint8> pointer;

  Pointer<Uint64> _word(int offset) => (pointer + offset).cast<Uint64>();

  int get iflag => _word(_iflagAt).value;
  set iflag(int value) => _word(_iflagAt).value = value;
  int get oflag => _word(_oflagAt).value;
  set oflag(int value) => _word(_oflagAt).value = value;
  int get cflag => _word(_cflagAt).value;
  set cflag(int value) => _word(_cflagAt).value = value;
  int get lflag => _word(_lflagAt).value;
  set lflag(int value) => _word(_lflagAt).value = value;
  int get ispeed => _word(_ispeedAt).value;
  set ispeed(int value) => _word(_ispeedAt).value = value;
  int get ospeed => _word(_ospeedAt).value;
  set ospeed(int value) => _word(_ospeedAt).value = value;

  int cc(int index) => pointer[_ccAt + index];
  void setCc(int index, int value) => pointer[_ccAt + index] = value;

  void free() => calloc.free(pointer);
}

// ---------------------------------------------------------- native bindings

final int Function(Pointer<Utf8>, int) _open = _libc
    .lookupFunction<Int Function(Pointer<Utf8>, Int), int Function(Pointer<Utf8>, int)>('open');

final int Function(int) close = _libc
    .lookupFunction<Int Function(Int), int Function(int)>('close');

final int Function(int, Pointer<Uint8>, int) _read = _libc.lookupFunction<
    IntPtr Function(Int, Pointer<Uint8>, IntPtr),
    int Function(int, Pointer<Uint8>, int)>('read');

final int Function(int, Pointer<Uint8>, int) _write = _libc.lookupFunction<
    IntPtr Function(Int, Pointer<Uint8>, IntPtr),
    int Function(int, Pointer<Uint8>, int)>('write');

final int Function(int, Pointer<Uint8>) tcgetattr = _libc.lookupFunction<
    Int Function(Int, Pointer<Uint8>),
    int Function(int, Pointer<Uint8>)>('tcgetattr');

final int Function(int, int, Pointer<Uint8>) tcsetattr = _libc.lookupFunction<
    Int Function(Int, Int, Pointer<Uint8>),
    int Function(int, int, Pointer<Uint8>)>('tcsetattr');

final int Function(int, int) flock = _libc
    .lookupFunction<Int Function(Int, Int), int Function(int, int)>('flock');

final int Function(int, int) tcflush = _libc
    .lookupFunction<Int Function(Int, Int), int Function(int, int)>('tcflush');

/// `ioctl` is variadic. On Apple arm64 variadic arguments are passed on the
/// stack rather than in registers, so declaring it with a fixed third
/// parameter would read garbage. `VarArgs` makes Dart use the right convention.
final int Function(int, int, Pointer<Int32>) _ioctlInt = _libc.lookupFunction<
    Int Function(Int, UnsignedLong, VarArgs<(Pointer<Int32>,)>),
    int Function(int, int, Pointer<Int32>)>('ioctl');

final int Function(int, int) _ioctlNone = _libc.lookupFunction<
    Int Function(Int, UnsignedLong),
    int Function(int, int)>('ioctl');

final Pointer<Int32> Function() _errnoLocation = _libc
    .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>('__error');

final Pointer<Utf8> Function(int) _strerror = _libc
    .lookupFunction<Pointer<Utf8> Function(Int), Pointer<Utf8> Function(int)>('strerror');

// Only the tests use these two; they open a pseudo-terminal pair so the whole
// stack can be exercised without a scanner.
final int Function(Pointer<Int32>, Pointer<Int32>, Pointer<Uint8>,
        Pointer<Uint8>, Pointer<Uint8>) openpty =
    _libc.lookupFunction<
        Int Function(Pointer<Int32>, Pointer<Int32>, Pointer<Uint8>,
            Pointer<Uint8>, Pointer<Uint8>),
        int Function(Pointer<Int32>, Pointer<Int32>, Pointer<Uint8>,
            Pointer<Uint8>, Pointer<Uint8>)>('openpty');

// ------------------------------------------------------------- friendly API

int get errno => _errnoLocation().value;

String errnoMessage(int code) => _strerror(code).toDartString();

/// `open(2)`; returns the descriptor, or -1 with [errno] set.
int openPath(String path, int flags) {
  final native = path.toNativeUtf8();
  try {
    return _open(native, flags);
  } finally {
    calloc.free(native);
  }
}

/// Non-blocking read into a fresh buffer. Returns the bytes, an empty list when
/// nothing is waiting, or null after setting [errno] for a real failure.
List<int>? readBytes(int fd, int count) {
  final buffer = calloc<Uint8>(count);
  try {
    final got = _read(fd, buffer, count);
    if (got < 0) {
      final code = errno;
      if (code == eagain || code == eintr) return const <int>[];
      return null;
    }
    return buffer.asTypedList(got).toList(growable: false);
  } finally {
    calloc.free(buffer);
  }
}

/// Write as much of [data] as the port will take; returns the count written,
/// 0 when it would block, or -1 with [errno] set.
int writeBytes(int fd, List<int> data) {
  final buffer = calloc<Uint8>(data.length);
  try {
    buffer.asTypedList(data.length).setAll(0, data);
    final put = _write(fd, buffer, data.length);
    if (put < 0) {
      final code = errno;
      if (code == eagain || code == eintr) return 0;
    }
    return put;
  } finally {
    calloc.free(buffer);
  }
}

/// `ioctl(fd, request, &value)`; returns the result and leaves the value in
/// [out] when the request fills it.
int ioctlInt(int fd, int request, [int value = 0, List<int>? out]) {
  final cell = calloc<Int32>()..value = value;
  try {
    final result = _ioctlInt(fd, request, cell);
    if (out != null) {
      out
        ..clear()
        ..add(cell.value);
    }
    return result;
  } finally {
    calloc.free(cell);
  }
}

/// `ioctl(fd, request)` for requests that take no argument (TIOCEXCL).
int ioctlNone(int fd, int request) => _ioctlNone(fd, request);

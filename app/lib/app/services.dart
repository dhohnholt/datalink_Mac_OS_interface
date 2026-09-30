import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:datalink_core/datalink_core.dart';
import 'package:datalink_serial_posix/datalink_serial_posix.dart';
import 'package:file_selector/file_selector.dart';

import '../features/classes/class_book.dart';

/// The few things that need the operating system's own dialogs. Behind an
/// interface so screens can be tested without opening a panel.
abstract interface class PlatformActions {
  /// Offer a Save panel and write [text] where the teacher chooses. Returns the
  /// path written, or null if they cancelled.
  Future<String?> saveText({
    required String suggestedName,
    required String text,
    required String extension,
  });
}

class SystemPlatformActions implements PlatformActions {
  const SystemPlatformActions();

  @override
  Future<String?> saveText({
    required String suggestedName,
    required String text,
    required String extension,
  }) async {
    final location = await getSaveLocation(
      suggestedName: suggestedName,
      acceptedTypeGroups: [
        XTypeGroup(label: extension.toUpperCase(), extensions: [extension]),
      ],
    );
    if (location == null) return null;
    await XFile.fromData(
      Uint8List.fromList(utf8.encode(text)),
      mimeType: 'text/plain',
      name: suggestedName,
    ).saveTo(location.path);
    return location.path;
  }
}

/// Everything the screens share: the database, the scanner, and the layer that
/// turns them into what a screen shows.
class AppServices {
  AppServices({
    required this.store,
    required this.workspace,
    required this.scanner,
    required this.actions,
    required this.dataDirectory,
  }) : classBook = ClassBook(store);

  final Store store;
  final Workspace workspace;
  final ScannerController scanner;
  final PlatformActions actions;

  /// The saved classes and the one scanning is using.
  final ClassBook classBook;

  /// Where sessions and the library live. Inside the sandbox this is the app's
  /// container, at the same `Application Support/DataLink Scanner/captures`
  /// path the Python app used, so the on-disk layout is unchanged.
  final Directory dataDirectory;

  /// Open the real thing: the library in Application Support and the USB
  /// serial transport.
  static Future<AppServices> start({Directory? dataDirectory}) async {
    final directory = dataDirectory ?? _defaultDataDirectory();
    directory.createSync(recursive: true);
    final store = Store.open('${directory.path}/library.sqlite3');
    final scanner = ScannerController(
      captureRoot: directory,
      store: store,
      transport: PosixSerialTransport(),
      clock: SystemClock(),
    );
    return AppServices(
      store: store,
      workspace: Workspace(store: store),
      scanner: scanner,
      actions: const SystemPlatformActions(),
      dataDirectory: directory,
    );
  }

  /// `~/Library/Application Support/DataLink Scanner/captures`. In the sandbox
  /// `HOME` is the container, so this lands inside it with no special casing.
  static Directory _defaultDataDirectory() {
    final home = Platform.environment['HOME'] ?? Directory.current.path;
    return Directory('$home/Library/Application Support/DataLink Scanner/captures');
  }

  Future<void> dispose() async {
    classBook.dispose();
    await scanner.dispose();
    store.close();
  }
}

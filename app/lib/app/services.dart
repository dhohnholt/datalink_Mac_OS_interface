import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:datalink_core/datalink_core.dart';
import 'package:datalink_serial_posix/datalink_serial_posix.dart';
import 'package:file_selector/file_selector.dart';
import 'package:url_launcher/url_launcher.dart';

import '../features/classes/class_book.dart';
import '../features/paper/orient_template.dart';
import '../features/paper/paper_model.dart';
import '../features/scan/scan_model.dart';
import '../features/settings/ttess_connection.dart';
import 'appearance.dart';
import 'keychain_store.dart';

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

  /// Show a folder in Finder.
  Future<void> reveal(String directory);

  /// Open a web address in the teacher's own browser, never inside the app.
  Future<void> openUrl(String url);

  /// Offer an Open panel for a scanned PDF. Returns its path, or null if they
  /// cancelled. Inside the sandbox this is the only way to reach the file.
  Future<String?> pickPdf();
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

  @override
  Future<void> reveal(String directory) async {
    await launchUrl(Uri.directory(directory));
  }

  @override
  Future<void> openUrl(String url) async {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  @override
  Future<String?> pickPdf() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'PDF', extensions: ['pdf'], uniformTypeIdentifiers: ['com.adobe.pdf']),
      ],
    );
    return file?.path;
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
    required this.ttess,
    this.portPollInterval = const Duration(seconds: 2),
    BatchReader? paperReader,
    PageCounter? pageCounter,
    PageCache? pageCache,
  })  : classBook = ClassBook(store),
        connection = TtessConnection(ttess),
        pageCache = pageCache ?? PageCache(Directory('${dataDirectory.path}/paper-cache')) {
    paper = PaperModel(
      store: store,
      classBook: classBook,
      cache: this.pageCache,
      reader: paperReader ?? _readWithBundledTemplate,
      pageCounter: pageCounter ?? countPdfPages,
    );
  }

  final Store store;
  final Workspace workspace;
  final ScannerController scanner;
  final PlatformActions actions;

  /// The client for the teacher's own reporting site.
  final TtessClient ttess;

  /// The saved classes and the one scanning is using.
  final ClassBook classBook;

  /// Light, dark or follow the Mac.
  late final Appearance appearance = Appearance(store);

  /// Whether this Mac is connected to the reporting site.
  final TtessConnection connection;

  /// Page pictures kept from paper batches, so a sheet can be looked at later.
  final PageCache pageCache;

  /// The Paper tab: choose a PDF, read it, file the result.
  late final PaperModel paper;

  Future<GrayImage>? _template;

  Future<Map<String, Object?>> _readWithBundledTemplate(PaperRequest request, PaperProgress progress) async {
    final template = await (_template ??= loadOrientTemplate());
    return readBatch(request: request, orientTemplate: template, cache: pageCache, onProgress: progress);
  }

  /// What the Scan tab decides. It lives here, not in the screen, because the
  /// old page kept every tab alive at once: a sheet that arrives while the
  /// teacher is looking at Sessions must still be saved or put up for review.
  late final ScanModel scan = ScanModel(this, portPollInterval: portPollInterval);

  /// Where sessions and the library live. Inside the sandbox this is the app's
  /// container, at the same `Application Support/DataLink Scanner/captures`
  /// path the Python app used, so the on-disk layout is unchanged.
  final Directory dataDirectory;

  /// How often the Scan tab looks for a newly plugged-in scanner. Null turns
  /// the polling off, which tests need so no timer outlives them.
  final Duration? portPollInterval;

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
    final services = AppServices(
      store: store,
      workspace: Workspace(store: store),
      scanner: scanner,
      actions: const SystemPlatformActions(),
      dataDirectory: directory,
      ttess: TtessClient(
        store: store,
        secrets: const KeychainSecretStore(),
        http: IoHttpTransport(),
      ),
    );
    // Who is connected is not asked here: that reads the Keychain, which can
    // prompt. Settings and the upload pane ask when first shown.
    return services;
  }

  /// `~/Library/Application Support/DataLink Scanner/captures`. In the sandbox
  /// `HOME` is the container, so this lands inside it with no special casing.
  static Directory _defaultDataDirectory() {
    final home = Platform.environment['HOME'] ?? Directory.current.path;
    return Directory('$home/Library/Application Support/DataLink Scanner/captures');
  }

  Future<void> dispose() async {
    scan.dispose();
    paper.dispose();
    appearance.dispose();
    classBook.dispose();
    connection.dispose();
    await scanner.dispose();
    store.close();
  }
}

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:datalink_core/datalink_core.dart';
import 'package:datalink_scanner/app/app.dart';
import 'package:datalink_scanner/app/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:datalink_scanner/features/paper/paper_model.dart';

import '../support/live_fake.dart';
import '../support/test_services.dart';

/// Makes the Mac App Store screenshots. Not part of the normal suite: it only
/// runs when DATALINK_SCREENSHOT_DIR names a folder to write into.
///
///   DATALINK_SCREENSHOT_DIR=AppStore/screenshots/mac-2560x1600 flutter test test/screenshots
///
/// Everything shown is invented: names, IDs and answers are made up here, and
/// nothing is read from the library or from a scan. Each image is the app's own
/// content area at 1280 x 800, drawn at twice that for a Retina display.
final String? outputDirectory = Platform.environment['DATALINK_SCREENSHOT_DIR'];

const students = [
  'Amara Okafor', 'Ben Whitfield', 'Camila Duarte', 'Dev Patel', 'Elena Petrova', 'Finn Gallagher',
  'Grace Nakamura', 'Hector Salazar', 'Imani Brooks', 'Jonas Lindqvist', 'Keiko Tanaka', 'Liam Dubois',
  'Maya Hassan', 'Noah Fitzgerald', 'Olivia Reyes', 'Priya Raman', 'Quinn Abbott', 'Rosa Mendes',
];

Future<void> loadFonts() async {
  Future<void> load(String family, List<String> paths) async {
    final loader = FontLoader(family);
    for (final path in paths) {
      final bytes = File(path).readAsBytesSync();
      loader.addFont(Future.value(ByteData.sublistView(Uint8List.fromList(bytes))));
    }
    await loader.load();
  }

  // The same system font the app uses on a Mac, and the Material icons.
  await load('.AppleSystemUIFont', ['/System/Library/Fonts/SFNS.ttf']);
  const sdk = '/opt/homebrew/Caskroom/flutter/3.47.5/flutter/bin/cache/artifacts/material_fonts';
  await load('Menlo', ['/System/Library/Fonts/Menlo.ttc']);
  await load('MaterialIcons', ['$sdk/MaterialIcons-Regular.otf']);
  await load('Roboto', ['$sdk/Roboto-Regular.ttf']);
}

List<String> answerKey(int count) {
  final random = math.Random(5);
  return [for (var i = 0; i < count; i++) 'ABCDE'[random.nextInt(5)]];
}

List<String> sheet(List<String> key, double skill, math.Random random) => [
      for (final correct in key)
        random.nextDouble() < skill ? correct : 'ABCDE'.replaceAll(correct, '')[random.nextInt(4)],
    ];

void seed(Store store) {
  store
    ..saveClass('4th Period Government', [
      for (var i = 0; i < students.length; i++) {'id': '${240101 + i}', 'name': students[i]},
    ])
    ..saveClass('5th Period Economics', [
      for (var i = 0; i < 6; i++) {'id': '${250201 + i}', 'name': students[students.length - 1 - i]},
    ])
    ..setSetting('selected_class', '4th Period Government')
    ..setSetting('test_name', 'Unit 1 Exam')
    ..setSetting('question_count', '25');
  const questions = 25;
  final key = answerKey(questions);
  final random = math.Random(11);
  int add(String name, String className, int count, List<String> roster, {int seedOffset = 0}) {
    final id = store.createSession(name, className, count);
    store.addScan(id, {
      'number': 1,
      'role': 'key',
      'answered_count': count,
      'responses': key.take(count).toList(),
    });
    for (var i = 0; i < roster.length; i++) {
      final responses = sheet(key.take(count).toList(), 0.62 + 0.03 * ((i + seedOffset) % 13), random);
      store.addScan(id, {
        'number': i + 2,
        'role': 'student',
        'student_id': '${240101 + i}',
        'student_name': roster[i],
        'answered_count': count,
        'responses': responses,
      });
    }
    return id;
  }

  add('Weekly Quiz 5.5', '5th Period Economics', 25, students.sublist(12), seedOffset: 4);
  add('Chapter 3 Quiz', '4th Period Government', 25, students.sublist(0, 14), seedOffset: 7);
  final first = add('Unit 1 Exam', '4th Period Government', questions, students.sublist(0, 17));
  // One sheet with a double mark, so the Review pane has something to show.
  final scans = store.sessionScans(first);
  final doubled = List<String>.of((scans[3]['responses']! as List).cast<String>())..[6] = 'AC';
  store.updateScan(first, 4, responses: doubled);
}

void main() {
  final directory = outputDirectory;
  if (directory == null) {
    test('screenshots (set DATALINK_SCREENSHOT_DIR to make them)', () {}, skip: 'not asked for');
    return;
  }

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadFonts();
    Directory(directory).createSync(recursive: true);
  });

  final key = GlobalKey();

  // Drawn as a Mac draws it: macOS typography, no scroll bars.
  void scene(String name, Future<void> Function(WidgetTester tester) body) {
    testWidgets(name, (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        await body(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  Future<AppServices> open(
    WidgetTester tester, {
    ThemeMode mode = ThemeMode.light,
    LiveFakeTransport? device,
    TickClock? clock,
    BatchReader? paperReader,
  }) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // A clock that moves on a minute at each use, so the sessions have
    // different, believable times and the newest is the one made last.
    var moment = DateTime.utc(2026, 9, 18, 14, 3);
    // A real file, so the storage line shows a believable size.
    final folder = Directory.systemTemp.createTempSync('screenshot-library-');
    addTearDown(() => folder.deleteSync(recursive: true));
    final store = Store.open('${folder.path}/library.sqlite3', now: () => moment = moment.add(const Duration(minutes: 1)));
    seed(store);
    final services = testServices(
      store: store,
      transport: device,
      clock: clock,
      pageCounter: (_) => 36,
      paperReader: paperReader,
    );
    services.appearance.set(mode);
    addTearDown(services.dispose);
    await tester.pumpWidget(RepaintBoundary(key: key, child: DataLinkApp(services: services)));
    await tester.pumpAndSettle();
    return services;
  }

  Future<void> shoot(WidgetTester tester, String name) async {
    await tester.pumpAndSettle();
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
    final bytes = await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    });
    File('$directory/$name.png').writeAsBytesSync(bytes!);
  }

  Future<void> tab(WidgetTester tester, String label) async {
    await tester.tap(find.text(label).first);
    await tester.pumpAndSettle();
  }

  Future<void> openFirstSession(WidgetTester tester) async {
    await tab(tester, 'Sessions');
    await tester.tap(find.text('View').first);
    await tester.pumpAndSettle();
  }

  scene('01 item analysis', (tester) async {
    await open(tester);
    await openFirstSession(tester);
    await tab(tester, 'Analysis');
    await shoot(tester, '01_item_analysis');
  });

  scene('02 scanning a class', (tester) async {
    final clock = TickClock();
    final device = LiveFakeTransport(clock: clock);
    await open(tester, device: device, clock: clock);
    await tester.tap(find.text('Connect and start session'));
    for (var i = 0; i < 90; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final liveKey = answerKey(25);
    final random = math.Random(3);
    device.sendRecord(liveKey, studentId: '');
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    for (var s = 0; s < 4; s++) {
      device.sendRecord(sheet(liveKey, 0.7 + 0.05 * s, random), studentId: '${240101 + s}');
      for (var i = 0; i < 14; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold).first)).clearSnackBars();
    await tester.pumpAndSettle();
    await shoot(tester, '02_scanning_a_class');
    await tester.tap(find.text('Disconnect'));
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  });

  scene('03 sheet by sheet', (tester) async {
    await open(tester);
    await openFirstSession(tester);
    await shoot(tester, '03_sheet_by_sheet_results');
  });

  scene('04 student scores, dark', (tester) async {
    await open(tester, mode: ThemeMode.dark);
    await openFirstSession(tester);
    await tab(tester, 'Analysis');
    await tester.tap(find.text('Student scores'));
    await tester.pumpAndSettle();
    await shoot(tester, '04_student_scores_dark');
  });

  scene('05 answer key', (tester) async {
    await open(tester);
    await openFirstSession(tester);
    await tab(tester, 'Analysis');
    await tester.tap(find.text('Answer key'));
    await tester.pumpAndSettle();
    await shoot(tester, '05_answer_key');
  });

  scene('06 saved sessions', (tester) async {
    await open(tester);
    await tab(tester, 'Sessions');
    await shoot(tester, '06_saved_sessions');
  });

  scene('07 classes and roster', (tester) async {
    await open(tester);
    await tab(tester, 'Classes');
    await tester.tap(find.text('Edit').first);
    await tester.pumpAndSettle();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await shoot(tester, '07_classes_and_roster');
  });

  scene('08 reading a paper batch', (tester) async {
    // The reader could not settle two questions on the key sheet, which is the
    // moment the app asks for help instead of guessing.
    final services = await open(
      tester,
      paperReader: (request, progress) async => throw const AnswerKeyException(
        'The answer key could not be read on question 14, question 22.',
        {
          'key_page': 1,
          'unresolved': {'14': 'MULTIPLE', '22': 'BLANK'},
          'pages': '/nowhere',
        },
      ),
    );
    (services.actions as RecordingActions).nextPdfPath = '/Users/teacher/Scans/Unit 2 Exam - 5th Period.pdf';
    await tab(tester, 'Paper');
    await tester.tap(find.text('Choose PDF…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Read the sheets'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(SegmentedButton<String>).first, matching: find.text('C')));
    await tester.pumpAndSettle();
    await shoot(tester, '08_reading_a_paper_batch');
  });

  scene('09 review', (tester) async {
    await open(tester);
    await openFirstSession(tester);
    await tab(tester, 'Analysis');
    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();
    await shoot(tester, '09_review');
  });
}

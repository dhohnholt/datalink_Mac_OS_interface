import 'dart:io';

import 'package:datalink_core/datalink_core.dart';
import 'package:test/test.dart';

import 'support/synthetic_sheets.dart';

void main() {
  late Directory work;
  late Store store;
  late PageCache cache;
  late int id;

  setUp(() {
    work = Directory.systemTemp.createTempSync('makeup-test-');
    store = Store.open(':memory:');
    cache = PageCache(Directory('${work.path}/cache'));
    final original = Directory('${cache.root.path}/original')
      ..createSync(recursive: true);
    File('${original.path}/${pagePictureName(1)}')
        .writeAsStringSync('original key image');
    File('${original.path}/${pagePictureName(2)}')
        .writeAsStringSync('original student image');
    id = store.createSession(
      'Unit 1',
      'Period 4',
      3,
      source: 'paper',
      pageCache: original.path,
    );
    store.addScan(id, {
      'number': 1,
      'role': 'key',
      'responses': ['A', 'B', 'C'],
    });
    store.addScan(id, {
      'number': 2,
      'role': 'student',
      'student_id': '123456',
      'responses': ['A', 'B', 'C'],
    });
  });
  tearDown(() {
    store.close();
    work.deleteSync(recursive: true);
  });

  Future<Map<String, Object?>> makeup() async {
    final template = syntheticTemplate();
    final file = File('${work.path}/makeup.pdf')
      ..writeAsBytesSync(
        syntheticPdf([
          syntheticSheet(
            template,
            answers: ['A', 'B', 'C', ...List.filled(47, '')],
            studentId: '654321',
          ),
        ]),
      );
    return readBatch(
      request: PaperRequest(
        pdf: file,
        savedKey: savedPaperKey(store, id).key,
        questionCount: 3,
        checkQuestionCount: false,
      ),
      orientTemplate: template,
      cache: cache,
      workers: 1,
    );
  }

  test('one student PDF uses saved key, appends, rescores and keeps both sets of pictures', () async {
    final workspace = Workspace(store: store);
    final before = workspace.analysisReport(id);
    final originalScans = store.sessionScans(id);
    final originalSession = store.session(id)!;
    final report = await makeup();
    final students = (report['students']! as List).cast<Map<String, Object?>>();
    expect(
      students.single['page'],
      1,
      reason: 'page 1 is a student, never a replacement key',
    );
    expect((students.single['score']! as Map)['correct'], 3);
    appendReportToSession(store, cache, id, report);
    expect(store.listSessions(), hasLength(1));
    final scans = store.sessionScans(id);
    expect(scans.take(2), originalScans);
    expect(scans.last['number'], 3);
    expect(scans.last['student_id'], '654321');
    final updated = store.session(id)!;
    expect(updated['started_at'], originalSession['started_at']);
    expect(updated['name'], 'Unit 1');
    final directory = updated['page_cache']! as String;
    expect(
      File('$directory/${pagePictureName(1)}').readAsStringSync(),
      'original key image',
    );
    expect(
      File('$directory/${pagePictureName(2)}').readAsStringSync(),
      'original student image',
    );
    expect(workspace.sessionPage(id, 3), isNotNull);
    expect(workspace.analysisReport(id)['students'], hasLength(2));
    expect(workspace.analysisReport(id)['run_id'], isNot(before['run_id']));
  });

  test('duplicate IDs with leading zeros refuse the entire append and retain the cache', () {
    final original = store.session(id)!;
    final scans = store.sessionScans(id);
    expect(
      () => store.appendScans(id, [
        {
          'student_id': '654321',
          'responses': ['A', 'B', 'C'],
        },
        {
          'student_id': '00123456',
          'responses': ['A', 'B', 'C'],
        },
      ], pageCache: '/wrong'),
      throwsA(isA<StoreError>()),
    );
    expect(store.sessionScans(id), scans);
    expect(store.session(id), original);
  });

  test(
    'reimport does not add a duplicate or leave a staged image directory',
    () async {
      final report = await makeup();
      appendReportToSession(store, cache, id, report);
      final original = store.session(id)!;
      final directories = cache.root.listSync().length;
      expect(
        () => appendReportToSession(store, cache, id, report),
        throwsA(isA<StoreError>()),
      );
      expect(store.sessionScans(id), hasLength(3));
      expect(store.session(id), original);
      expect(cache.root.listSync(), hasLength(directories));
    },
  );

  test('a package without embedded answers reuses its saved version keys', () {
    final package = TestPackage.parse(
      'Stable item ID,Version 1,Version 2\nq1,1,2\nq2,2,1\n',
    );
    final packaged = store.createSession(
      'Versions',
      '',
      2,
      package: pyJsonEncode(package.toJson()),
    );
    store.addScan(packaged, {
      'number': 1,
      'role': 'key',
      'version': '1',
      'responses': ['A', 'B'],
    });
    store.addScan(packaged, {
      'number': 2,
      'role': 'key',
      'version': '2',
      'responses': ['C', 'D'],
    });
    final saved = savedPaperKey(store, packaged);
    expect(saved.key, isNull);
    expect(saved.package!.answers, {
      '1': {'q1': 'A', 'q2': 'B'},
      '2': {'q1': 'D', 'q2': 'C'},
    });
    expect(
      packageOf(store.session(packaged)!)!.hasAnswers,
      isFalse,
      reason: 'saved package is preserved',
    );
  });
}

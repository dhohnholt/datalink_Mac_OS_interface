import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:datalink_core/datalink_core.dart';

import '../../app/services.dart';
import 'paper_model.dart';

/// Reads one PDF through the real app services, in a throwaway library, and
/// describes the outcome in numbers. Run from a terminal against the built
/// app, it shows that the asset, the isolates, file access and the page cache
/// all work inside the sandbox. [spec] is `path:keyPage`.
Future<String> paperSelfTest(String spec) async {
  final cut = spec.lastIndexOf(':');
  final path = spec.substring(0, cut);
  final keyPage = int.parse(spec.substring(cut + 1));
  final directory = Directory.systemTemp.createTempSync('paper-selftest-');
  final services = await AppServices.start(dataDirectory: directory);
  final lines = <String>[];
  try {
    final watch = Stopwatch()..start();
    final model = services.paper;
    if (!model.setPdf(path)) return 'FAILED opening: ${model.error}';
    model.keyPage = keyPage;
    await model.run();
    lines.add('phase ${model.phase.name} in ${watch.elapsedMilliseconds} ms');
    if (model.phase != PaperPhase.done) {
      lines.add('message: ${model.message}');
      return lines.join('\n');
    }
    final scans = services.store.sessionScans(model.sessionId!);
    final students = scans.where((s) => s['role'] == 'student').toList();
    final digest = sha256.convert(utf8.encode(pyJsonEncode([for (final s in scans) s['responses']]))).toString();
    lines
      ..add('pages ${model.pageCount} · students ${students.length}')
      ..add('responses digest ${digest.substring(0, 12)}')
      ..add('cache ${model.cacheBytes} bytes in ${model.cacheBatches} batch');
    final detail = services.workspace.sessionDetail(model.sessionId!);
    lines.add('has pages ${detail['has_pages']} · analysis ${detail['analysis_available']}');
    return lines.join('\n');
  } finally {
    await services.dispose();
    directory.deleteSync(recursive: true);
  }
}

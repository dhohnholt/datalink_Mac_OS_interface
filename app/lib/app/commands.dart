import 'package:datalink_core/datalink_core.dart';
import 'package:flutter/material.dart' show ThemeMode;

import 'navigation.dart';
import 'services.dart';

const String repoUrl = 'https://github.com/dhohnholt/datalink_Mac_OS_interface';

/// Asks the teacher to confirm something; true to go ahead.
typedef Confirm = Future<bool> Function({
  required String title,
  required String message,
  String confirmLabel,
  bool destructive,
});

/// Everything the menu bar can do. The old app's menu clicked the buttons on
/// the hidden page; these do the same things directly, so they work from any
/// tab and can be tested without a menu.
class Commands {
  Commands({
    required this.services,
    required this.navigation,
    required this.toast,
    required this.confirm,
  });

  final AppServices services;
  final AppNavigation navigation;
  final void Function(String message) toast;
  final Confirm confirm;

  // ------------------------------------------------------------------- views

  void show(AppView view) => navigation.show(view);

  // ---------------------------------------------------------------- classes

  void newClass() {
    navigation.show(AppView.classes);
    services.classBook.requestEditor(null);
  }

  /// With no class selected this opens an empty editor, as the old menu did.
  void editClass() {
    navigation.show(AppView.classes);
    final selected = services.classBook.selectedName;
    services.classBook.requestEditor(selected.isEmpty ? null : selected);
  }

  void setAppearance(ThemeMode mode) => services.appearance.set(mode);

  // ------------------------------------------------------------------ paper

  /// Shows the Paper tab and offers the Open panel for a scanned PDF.
  Future<void> readPaperBatch() async {
    navigation.show(AppView.paper);
    final path = await services.actions.pickPdf();
    if (path != null) services.paper.setPdf(path);
  }

  // ---------------------------------------------------------------- exports

  bool get _viewingASession => navigation.view == AppView.sessions && navigation.sessionId != null;

  /// A saved session's CSV when one is open on Sessions; otherwise the sheets
  /// on the Scan tab.
  Future<void> exportCsv() async {
    final String filename;
    final String csv;
    if (_viewingASession) {
      final export = services.workspace.sessionCsv(navigation.sessionId!);
      filename = export.filename;
      csv = export.csv;
    } else {
      final export = services.scan.exportCsv();
      filename = export.filename;
      csv = export.csv;
    }
    final path = await services.actions.saveText(suggestedName: filename, text: csv, extension: 'csv');
    if (path != null) toast('Saved $filename');
  }

  Future<void> exportAnalysis() async {
    if (!_viewingASession) {
      toast('Open a saved session first, then export its item analysis');
      return;
    }
    try {
      final export = services.workspace.analysisDownload(navigation.sessionId!);
      final path = await services.actions.saveText(
        suggestedName: export.filename,
        text: export.json,
        extension: 'json',
      );
      if (path != null) toast('Saved ${export.filename}');
    } on AnalysisError catch (error) {
      toast(error.message);
    }
  }

  Future<void> openSessionFolder() => services.actions.reveal(services.dataDirectory.path);

  // ---------------------------------------------------------------- scanning

  Future<void> startSession() => services.scan.start();

  Future<void> endSession() async {
    if (!services.scan.canEnd) return;
    final ok = await confirm(
      title: 'End session',
      message: 'End this session? The sheets already captured stay saved under Sessions.',
      confirmLabel: 'End session',
      destructive: false,
    );
    if (ok) services.scan.end();
  }

  Future<void> resetScanner() => services.scan.resetScanner();

  Future<void> disconnect() => services.scan.disconnect();

  void skipStudent() => services.scan.skipStudent();

  void startAtFirstStudent() => services.scan.startAtFirst();

  Future<void> clearView() async {
    if (!services.scan.canClear) {
      services.scan.clearView();
      return;
    }
    final ok = await confirm(
      title: 'Clear view',
      message: 'Clear the scans shown here? The saved session is not deleted.',
      confirmLabel: 'Clear',
      destructive: true,
    );
    if (ok) services.scan.clearView();
  }

  void toggleProtocol() => services.scan.toggleProtocol();

  // -------------------------------------------------------------------- help

  Future<void> openHelp() => services.actions.openUrl('$repoUrl#use');

  Future<void> openProtocolNotes() => services.actions.openUrl('$repoUrl/blob/main/docs/PROTOCOL.md');

  Future<void> reportIssue() => services.actions.openUrl('$repoUrl/issues');
}

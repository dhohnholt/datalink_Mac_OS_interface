import 'package:datalink_core/datalink_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/scope.dart';
import '../../ui/widgets.dart';
import '../classes/class_book.dart';
import 'review_dialog.dart';
import 'scan_model.dart';

/// Connect the scanner, run a session, and watch sheets arrive.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  ScanModel? _model;
  bool _dialogOpen = false;
  final _testName = TextEditingController();
  final _count = TextEditingController();
  late final FocusNode _countFocus = FocusNode()
    ..addListener(() {
      if (!_countFocus.hasFocus) _model?.commitQuestionCount(_count.text);
    });

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_model != null) return;
    final model = ScanModel(
      Services.of(context),
      portPollInterval: Services.of(context).portPollInterval,
    );
    model.onMessage = (message) {
      if (mounted) showToast(context, message);
    };
    model.addListener(_afterChange);
    _testName.text = model.testName;
    _count.text = '${model.questionCount}';
    _model = model;
  }

  @override
  void dispose() {
    _model?.removeListener(_afterChange);
    _model?.dispose();
    _testName.dispose();
    _count.dispose();
    _countFocus.dispose();
    super.dispose();
  }

  /// Open the review dialog when a sheet needs a person. The dialog closes
  /// itself, including when the sheet is dealt with some other way.
  void _afterChange() {
    final model = _model!;
    if (model.pendingPlan != null && !_dialogOpen) {
      _dialogOpen = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || model.pendingPlan == null) {
          _dialogOpen = false;
          return;
        }
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (context) => ReviewDialog(model: model),
        ).whenComplete(() => _dialogOpen = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = _model!;
    final book = Services.of(context).classBook;
    return ListenableBuilder(
      listenable: Listenable.merge([model, book]),
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(24),
        children: [
          _connection(context, model, book),
          MetricRow(tiles: [
            MetricTile(label: 'Sheets captured', value: '${model.snapshot.recordCount}'),
            MetricTile(label: 'Latest response count', value: model.latestAnswered),
            MetricTile(label: 'Session', value: model.sessionLabel),
          ]),
          _workflow(context, model),
          _liveScans(context, model),
          _activity(context, model),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- sections

  Widget _connection(BuildContext context, ScanModel model, ClassBook book) {
    final ports = model.snapshot.ports;
    return SectionCard(
      title: 'Scanner connection',
      subtitle: model.connectionDetail,
      trailing: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _badge(model),
          FilledButton(
            onPressed: model.canStart ? model.start : null,
            child: Text(model.connectLabel),
          ),
          OutlinedButton(onPressed: model.canEnd ? () => _end(model) : null, child: const Text('End session')),
          Tooltip(
            message: 'Re-send the handshake. This does not change the mode the scanner is in — '
                'for that, use the Reset button on the device itself.',
            child: TextButton(
              onPressed: model.canReset ? model.resetScanner : null,
              child: const Text('Re-send handshake'),
            ),
          ),
          TextButton(onPressed: model.canDisconnect ? model.disconnect : null, child: const Text('Disconnect')),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 16,
            runSpacing: 16,
            children: [
              SizedBox(
                width: 280,
                child: TextField(
                  controller: _testName,
                  decoration: const InputDecoration(
                    labelText: 'Test name',
                    hintText: 'Unit 1 Exam — 4th Period',
                  ),
                  onChanged: model.setTestName,
                ),
              ),
              SizedBox(
                width: 220,
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: book.classes.any((c) => c['name'] == model.className) ? model.className : '',
                  key: ValueKey('class-${model.className}-${book.classes.length}'),
                  decoration: const InputDecoration(labelText: 'Class'),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('No roster')),
                    for (final c in book.classes)
                      DropdownMenuItem(value: c['name']! as String, child: Text(c['name']! as String)),
                  ],
                  onChanged: (value) => model.selectClass(value ?? ''),
                ),
              ),
              SizedBox(
                width: 300,
                child: DropdownButtonFormField<StudentMatching>(
                  isExpanded: true,
                  initialValue: model.matching,
                  decoration: InputDecoration(
                    labelText: 'Student matching',
                    suffixIcon: _hint(
                      'About student matching',
                      'By ID reads the bubbled ID and finds the student, so sheets can be fed in any '
                          'order. Roster order ignores the ID area and takes the class list in turn.',
                    ),
                  ),
                  items: const [
                    DropdownMenuItem(value: StudentMatching.id, child: Text('By bubbled ID — any order')),
                    DropdownMenuItem(value: StudentMatching.roster, child: Text('In roster order — ignore ID area')),
                    DropdownMenuItem(value: StudentMatching.manual, child: Text('Ask for every sheet')),
                  ],
                  onChanged: (value) => model.setMatching(value ?? StudentMatching.id),
                ),
              ),
              SizedBox(
                width: 260,
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: ports.contains(model.port) ? model.port : '',
                  key: ValueKey('ports-${ports.join(',')}'),
                  decoration: const InputDecoration(labelText: 'Serial port'),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('Auto-detect scanner')),
                    for (final p in ports) DropdownMenuItem(value: p, child: Text(p)),
                  ],
                  onChanged: model.portLocked ? null : (value) => model.port = value ?? '',
                ),
              ),
              SizedBox(
                width: 180,
                child: TextField(
                  controller: _count,
                  focusNode: _countFocus,
                  enabled: !model.countLocked,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    labelText: 'Questions per form',
                    suffixIcon: _hint(
                      'About questions per form',
                      '1–100. Set the real form length so unanswered questions at the end are kept as blanks.',
                    ),
                  ),
                  onSubmitted: (value) {
                    model.commitQuestionCount(value);
                    _count.text = '${model.questionCount}';
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text.rich(
            TextSpan(children: [
              const TextSpan(
                text: 'Press Reset on the scanner until its display reads Scan Mode Ready before '
                    'feeding anything. ',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const TextSpan(
                text: 'The mode is chosen with that button and nothing the app sends can change it — '
                    'in the wrong mode the scanner holds the sheet, asks for its other side, and tells '
                    'the app nothing at all. Starting a session sends the command sequence recovered '
                    'from DataLink Connect. Each session gets its own answer key, its own numbering and '
                    'its own file — end one and start the next for the following class.',
              ),
            ]),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _badge(ScanModel model) {
    final tone = switch (model.snapshot.state) {
      'connected' => model.scanning ? Tone.good : Tone.neutral,
      'error' => Tone.bad,
      'connecting' => Tone.warn,
      _ => Tone.neutral,
    };
    return Semantics(
      liveRegion: true,
      label: 'Scanner status: ${model.badgeLabel}',
      excludeSemantics: true,
      child: StatusPill(text: model.badgeLabel, tone: tone),
    );
  }

  Widget _hint(String label, String text) => Semantics(
        label: '$label. $text',
        excludeSemantics: true,
        child: Tooltip(
          message: text,
          triggerMode: TooltipTriggerMode.tap,
          showDuration: const Duration(seconds: 8),
          child: const Icon(Icons.info_outline, size: 18),
        ),
      );

  Widget _workflow(BuildContext context, ScanModel model) {
    final flow = model.workflow;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: model.scanning && !model.hasKey ? scheme.tertiaryContainer : scheme.surfaceContainerLow,
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Semantics(
          container: true,
          label: '${flow.title}. ${flow.detail}',
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(
                child: CircleAvatar(
                  radius: 16,
                  backgroundColor: scheme.primary,
                  foregroundColor: scheme.onPrimary,
                  child: Text(flow.step),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(flow.title, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(flow.detail),
                    const SizedBox(height: 4),
                    Text(model.rosterSummary, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Wrap(spacing: 8, children: [
                if (model.canStartAtFirst)
                  TextButton(onPressed: model.startAtFirst, child: const Text('Start at first student')),
                if (model.canSkip)
                  OutlinedButton(onPressed: model.skipStudent, child: const Text('Skip absent')),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _liveScans(BuildContext context, ScanModel model) {
    final records = model.recordsNewestFirst;
    final columns = records.fold<int>(
      model.questionCount,
      (most, r) => (r['responses']! as List).length > most ? (r['responses']! as List).length : most,
    );
    return SectionCard(
      title: 'Live scans',
      subtitle: 'Newest first. The first sheet is the answer key.',
      trailing: Wrap(spacing: 8, children: [
        OutlinedButton(
          onPressed: records.isEmpty ? null : () => _export(model),
          child: const Text('Export CSV'),
        ),
        Tooltip(
          message: model.canClear
              ? ''
              : 'Not while a session is running — the sheets on screen are the ones being recorded',
          child: TextButton(
            onPressed: model.canClear ? () => _clear(model) : null,
            child: const Text('Clear view'),
          ),
        ),
      ]),
      child: records.isEmpty
          ? const EmptyState(
              title: 'No sheets captured yet',
              message: 'Start a session, then feed the answer key and your student sheets.',
              icon: Icons.document_scanner_outlined,
            )
          : SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columnSpacing: 14,
                horizontalMargin: 8,
                columns: [
                  const DataColumn(label: Text('Scan')),
                  const DataColumn(label: Text('Student ID')),
                  const DataColumn(label: Text('Time')),
                  for (var q = 1; q <= columns; q++)
                    DataColumn(label: Semantics(label: 'Question $q', child: Text('Q$q'))),
                ],
                rows: [for (final r in records) _row(context, r, columns)],
              ),
            ),
    );
  }

  DataRow _row(BuildContext context, Map<String, Object?> record, int columns) {
    final isKey = record['role'] == 'key';
    final number = record['number']! as int;
    final name = (record['student_name'] as String?) ?? '';
    final id = (record['student_id'] as String?) ?? '';
    final responses = (record['responses']! as List).cast<String>();
    final scheme = Theme.of(context).colorScheme;
    final time = DateTime.tryParse('${record['received_at']}')?.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return DataRow(cells: [
      DataCell(Text(isKey ? 'Key' : 'Student ${number - 1}')),
      DataCell(name.isNotEmpty
          ? Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [Text(name), Text(id, style: Theme.of(context).textTheme.bodySmall)],
            )
          : Text(id.isEmpty ? '—' : id)),
      DataCell(Text(time == null ? '—' : '${two(time.hour)}:${two(time.minute)}:${two(time.second)}')),
      for (var q = 1; q <= columns; q++)
        DataCell(Builder(builder: (context) {
          final value = q <= responses.length ? responses[q - 1] : '';
          return Text(
            value.isEmpty ? '—' : value,
            style: TextStyle(
              color: value.isEmpty
                  ? scheme.onSurfaceVariant
                  : (value.length > 1 ? Tone.warn.foreground(scheme) : null),
              fontWeight: value.length > 1 ? FontWeight.w700 : null,
            ),
          );
        })),
    ]);
  }

  Widget _activity(BuildContext context, ScanModel model) {
    final entries = model.activity;
    return SectionCard(
      title: 'Activity',
      subtitle: 'Connection, protocol, and scan events.',
      trailing: TextButton(
        onPressed: model.toggleProtocol,
        child: Text(model.showProtocol ? 'Hide protocol details' : 'Show protocol details'),
      ),
      child: entries.isEmpty
          ? Text('Waiting for activity.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [for (final e in entries) _ActivityLine(entry: e)],
            ),
    );
  }

  // ----------------------------------------------------------------- actions

  Future<void> _end(ScanModel model) async {
    final ok = await confirmDialog(
      context,
      title: 'End session',
      message: 'End this session? The sheets already captured stay saved under Sessions.',
      confirmLabel: 'End session',
    );
    if (ok) model.end();
  }

  Future<void> _clear(ScanModel model) async {
    final ok = await confirmDialog(
      context,
      title: 'Clear view',
      message: 'Clear the scans shown here? The saved session is not deleted.',
      confirmLabel: 'Clear',
      destructive: true,
    );
    if (ok) model.clearView();
  }

  Future<void> _export(ScanModel model) async {
    final export = model.exportCsv();
    final path = await Services.of(context).actions.saveText(
          suggestedName: export.filename,
          text: export.csv,
          extension: 'csv',
        );
    if (path != null && mounted) showToast(context, 'Saved ${export.filename}');
  }
}

class _ActivityLine extends StatelessWidget {
  const _ActivityLine({required this.entry});

  final ActivityEntry entry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, tone) = switch (entry.kind) {
      'success' => (Icons.check_circle_outline, Tone.good),
      'warning' => (Icons.warning_amber_rounded, Tone.warn),
      'error' => (Icons.error_outline, Tone.bad),
      'protocol' => (Icons.swap_horiz, Tone.neutral),
      _ => (Icons.info_outline, Tone.neutral),
    };
    final label = switch (entry.kind) {
      'success' => 'Done',
      'warning' => 'Warning',
      'error' => 'Error',
      'protocol' => 'Protocol',
      _ => 'Info',
    };
    return Semantics(
      label: '${entry.time}. $label. ${entry.message}',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(entry.time, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(width: 12),
            Icon(icon, size: 16, color: tone.foreground(scheme)),
            const SizedBox(width: 8),
            Expanded(child: Text(entry.message, style: TextStyle(color: tone.foreground(scheme)))),
          ],
        ),
      ),
    );
  }
}

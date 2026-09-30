import 'package:datalink_core/datalink_core.dart';
import 'package:flutter/material.dart';

import '../../app/scope.dart';
import '../../ui/widgets.dart';
import 'format.dart';

/// Saved sessions, the storage they use, and one session's sheets.
class SessionsScreen extends StatefulWidget {
  const SessionsScreen({super.key});

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  int _pruneDays = 365;

  @override
  Widget build(BuildContext context) {
    final services = Services.of(context);
    final nav = Nav.of(context);
    final sessions = services.store.listSessions();
    final selected = nav.sessionId;
    final report = services.store.storageReport();

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        SectionCard(
          title: 'Saved sessions',
          subtitle: 'Every test you have scanned, newest first.',
          trailing: OutlinedButton.icon(
            onPressed: () {
              setState(() {});
              showToast(context, 'Sessions refreshed');
            },
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh'),
          ),
          child: sessions.isEmpty
              ? const EmptyState(
                  title: 'No saved sessions yet',
                  message: 'Start a session on the Scan tab, or read a paper batch, and it appears here.',
                  icon: Icons.history,
                )
              : Column(
                  children: [
                    for (final row in sessions)
                      _SessionRow(
                        row: row,
                        selected: row['id'] == selected,
                        onView: () => nav.openSession(row['id']! as int),
                        onRename: () => _rename(row),
                        onDelete: () => _delete(row),
                      ),
                  ],
                ),
        ),
        SectionCard(
          title: 'Storage',
          subtitle: storageSummary(report),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('Delete sessions older than'),
                  DropdownButton<int>(
                    value: _pruneDays,
                    items: [
                      for (final (label, days) in pruneChoices)
                        DropdownMenuItem(value: days, child: Text(label)),
                    ],
                    onChanged: (value) => setState(() => _pruneDays = value ?? _pruneDays),
                  ),
                  OutlinedButton(onPressed: _prune, child: const Text('Delete old sessions')),
                  TextButton(
                    onPressed: () => services.actions.reveal(services.dataDirectory.path),
                    child: const Text('Show in Finder'),
                  ),
                ],
              ),
              if (storagePathNote(report).isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: SelectableText(
                    storagePathNote(report),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        ),
        if (selected != null) _Detail(sessionId: selected, onChanged: () => setState(() {})),
      ],
    );
  }

  Future<void> _rename(Map<String, Object?> row) async {
    final services = Services.of(context);
    final name = await promptDialog(
      context,
      title: 'Name this session',
      initial: (row['name'] as String?) ?? '',
    );
    if (name == null || !mounted) return;
    services.workspace.renameSession(row['id']! as int, name);
    setState(() {});
  }

  Future<void> _delete(Map<String, Object?> row) async {
    final services = Services.of(context);
    final nav = Nav.read(context);
    final ok = await confirmDialog(
      context,
      title: 'Delete session',
      message: 'Delete this saved session and all of its scans? This cannot be undone.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final id = row['id']! as int;
    services.scanner.removeSessions([id]);
    if (nav.sessionId == id) nav.clearSession();
    setState(() {});
    showToast(context, 'Session deleted');
  }

  Future<void> _prune() async {
    final services = Services.of(context);
    final nav = Nav.read(context);
    final label = pruneChoices.firstWhere((c) => c.$2 == _pruneDays).$1;
    final doomed = services.workspace.sessionsOlderThan(_pruneDays);
    if (doomed.isEmpty) {
      showToast(context, 'No sessions are older than $label');
      return;
    }
    final ok = await confirmDialog(
      context,
      title: 'Delete old sessions',
      message: 'Delete ${doomed.length} session(s) older than $label? '
          'Their scans and log files are removed for good.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final result = services.scanner.removeSessions([for (final s in doomed) s['id']! as int]);
    nav.clearSession();
    setState(() {});
    showToast(context, 'Deleted ${result.sessions} session(s) and ${result.logs} log file(s)');
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.row,
    required this.selected,
    required this.onView,
    required this.onRename,
    required this.onDelete,
  });

  final Map<String, Object?> row;
  final bool selected;
  final VoidCallback onView;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final name = (row['name'] as String?)?.isNotEmpty == true ? row['name']! as String : 'Untitled';
    final className = (row['class_name'] as String?)?.isNotEmpty == true ? row['class_name']! as String : '—';
    final sheets = row['scan_count']! as int;
    final when = formatTimestamp(row['started_at'] as String?);
    return Semantics(
      container: true,
      selected: selected,
      label: '$name, $className, $sheets ${sheets == 1 ? 'sheet' : 'sheets'}, $when',
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        selected: selected,
        title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text('$when · $className · $sheets ${sheets == 1 ? 'sheet' : 'sheets'}'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            OutlinedButton(onPressed: onView, child: const Text('View')),
            const SizedBox(width: 4),
            TextButton(onPressed: onRename, child: const Text('Rename')),
            TextButton(
              onPressed: onDelete,
              style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
              child: const Text('Delete'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail({required this.sessionId, required this.onChanged});

  final int sessionId;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final services = Services.of(context);
    final Map<String, Object?> session;
    try {
      session = services.workspace.sessionDetail(sessionId);
    } on NotFoundError {
      return const SizedBox.shrink();
    }
    final scans = (session['scans']! as List).cast<Map<String, Object?>>();
    final questionCount = session['question_count']! as int;
    final columns = scans.fold<int>(
      questionCount,
      (most, scan) => (scan['responses']! as List).length > most ? (scan['responses']! as List).length : most,
    );
    final name = (session['name'] as String?)?.isNotEmpty == true ? session['name']! as String : 'Untitled session';
    final className = (session['class_name'] as String?)?.isNotEmpty == true ? session['class_name']! as String : 'no class';
    final available = session['analysis_available'] == true;

    return SectionCard(
      title: name,
      subtitle: '${formatTimestamp(session['started_at'] as String?)} · $className · '
          '${scans.length} sheets · $questionCount questions per form',
      trailing: Wrap(
        spacing: 8,
        children: [
          OutlinedButton(
            onPressed: () => _exportCsv(context),
            child: const Text('Export CSV'),
          ),
          Tooltip(
            message: available
                ? 'Scores every sheet and writes the item analysis JSON for upload'
                : (session['analysis_error'] as String?) ?? '',
            child: FilledButton(
              onPressed: available ? () => _exportAnalysis(context) : null,
              child: const Text('Export item analysis'),
            ),
          ),
          TextButton(onPressed: Nav.read(context).clearSession, child: const Text('Close')),
        ],
      ),
      child: scans.isEmpty
          ? const EmptyState(title: 'No sheets in this session')
          : SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columnSpacing: 14,
                horizontalMargin: 8,
                dataRowMinHeight: 40,
                dataRowMaxHeight: 52,
                columns: [
                  const DataColumn(label: Text('Scan')),
                  const DataColumn(label: Text('Student')),
                  const DataColumn(label: Text('Time')),
                  const DataColumn(label: Text('Answered'), numeric: true),
                  for (var q = 1; q <= columns; q++)
                    DataColumn(label: Semantics(label: 'Question $q', child: Text('Q$q'))),
                ],
                rows: [
                  for (final scan in scans) _row(context, scan, columns),
                ],
              ),
            ),
    );
  }

  DataRow _row(BuildContext context, Map<String, Object?> scan, int columns) {
    final number = scan['number']! as int;
    final isKey = scan['role'] == 'key';
    final who = (scan['student_name'] as String?)?.isNotEmpty == true
        ? scan['student_name']! as String
        : null;
    final id = (scan['student_id'] as String?) ?? '';
    final responses = (scan['responses']! as List).cast<String>();
    return DataRow(
      cells: [
        DataCell(Text(isKey ? 'Key' : 'Student ${number - 1}')),
        DataCell(
          who == null
              ? Text(id.isEmpty ? '—' : id)
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [Text(who), Text(id, style: Theme.of(context).textTheme.bodySmall)],
                ),
        ),
        DataCell(Text(formatTimestamp(scan['received_at'] as String?))),
        DataCell(Text('${scan['answered_count']}')),
        for (var q = 1; q <= columns; q++)
          _responseCell(context, scan, number, q, q <= responses.length ? responses[q - 1] : ''),
      ],
    );
  }

  DataCell _responseCell(BuildContext context, Map<String, Object?> scan, int number, int question, String value) {
    final scheme = Theme.of(context).colorScheme;
    final tone = value.isEmpty ? Tone.neutral : (value.length > 1 ? Tone.warn : Tone.good);
    final who = scan['role'] == 'key'
        ? 'Answer key'
        : ((scan['student_name'] as String?)?.isNotEmpty == true
            ? scan['student_name']! as String
            : ((scan['student_id'] as String?)?.isNotEmpty == true
                ? scan['student_id']! as String
                : 'Student ${number - 1}'));
    return DataCell(
      Semantics(
        button: true,
        label: 'Question $question, $who, '
            '${value.isEmpty ? 'blank' : value.length > 1 ? 'multiple marks $value' : 'answer $value'}. '
            'Activate to correct.',
        excludeSemantics: true,
        child: Text(
          value.isEmpty ? '—' : value,
          style: TextStyle(
            color: value.isEmpty ? scheme.onSurfaceVariant : tone.foreground(scheme),
            fontWeight: value.length > 1 ? FontWeight.w700 : null,
          ),
        ),
      ),
      onTap: () => _correct(context, scan, number, question, value),
    );
  }

  Future<void> _correct(
    BuildContext context,
    Map<String, Object?> scan,
    int number,
    int question,
    String current,
  ) async {
    final services = Services.of(context);
    final who = scan['role'] == 'key'
        ? 'Answer key'
        : ((scan['student_name'] as String?)?.isNotEmpty == true
            ? scan['student_name']! as String
            : ((scan['student_id'] as String?)?.isNotEmpty == true
                ? scan['student_id']! as String
                : 'Student ${number - 1}'));
    final chosen = await showDialog<String>(
      context: context,
      builder: (context) => _AnswerDialog(
        question: question,
        intro: current.isNotEmpty
            ? '$who · read as $current. Choose what the sheet actually shows.'
            : '$who · read as blank. Choose what the sheet actually shows, or confirm the blank.',
        current: current,
      ),
    );
    if (chosen == null || !context.mounted) return;
    if (chosen == current) {
      showToast(context, 'That is already what is recorded');
      return;
    }
    final responses = List<String>.of((scan['responses']! as List).cast<String>());
    while (responses.length < (services.workspace.sessionDetail(sessionId)['question_count']! as int)) {
      responses.add('');
    }
    responses[question - 1] = chosen;
    try {
      final result = services.workspace.correct(sessionId, [
        {'number': number, 'responses': responses},
      ]);
      showToast(
        context,
        result['applied'] == 1
            ? 'Question $question saved as ${chosen.isEmpty ? 'blank' : chosen}'
            : 'No change was made',
      );
    } on DataLinkError catch (error) {
      showToast(context, error.message);
    } on StoreError catch (error) {
      showToast(context, error.message);
    }
    onChanged();
  }

  Future<void> _exportCsv(BuildContext context) async {
    final services = Services.of(context);
    final export = services.workspace.sessionCsv(sessionId);
    final path = await services.actions.saveText(
      suggestedName: export.filename,
      text: export.csv,
      extension: 'csv',
    );
    if (path != null && context.mounted) showToast(context, 'Saved ${export.filename}');
  }

  Future<void> _exportAnalysis(BuildContext context) async {
    final services = Services.of(context);
    try {
      final export = services.workspace.analysisDownload(sessionId);
      final path = await services.actions.saveText(
        suggestedName: export.filename,
        text: export.json,
        extension: 'json',
      );
      if (path != null && context.mounted) showToast(context, 'Saved ${export.filename}');
    } on AnalysisError catch (error) {
      if (context.mounted) showToast(context, error.message);
    }
  }
}

class _AnswerDialog extends StatefulWidget {
  const _AnswerDialog({required this.question, required this.intro, required this.current});

  final int question;
  final String intro;
  final String current;

  @override
  State<_AnswerDialog> createState() => _AnswerDialogState();
}

class _AnswerDialogState extends State<_AnswerDialog> {
  late String _value = widget.current.length == 1 ? widget.current : '';

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Question ${widget.question}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.intro),
          const SizedBox(height: 12),
          RadioGroup<String>(
            groupValue: _value,
            onChanged: (value) => setState(() => _value = value ?? ''),
            child: Wrap(
              spacing: 8,
              children: [
                for (final letter in ['A', 'B', 'C', 'D', 'E', ''])
                  SizedBox(
                    width: 96,
                    child: RadioListTile<String>(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: letter,
                      title: Text(letter.isEmpty ? 'Blank' : letter),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, _value), child: const Text('Save')),
      ],
    );
  }
}

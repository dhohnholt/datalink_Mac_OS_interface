import 'package:flutter/material.dart';
import 'package:datalink_core/datalink_core.dart';
import '../../app/scope.dart';

import '../../ui/widgets.dart';
import 'student_identity_dialog.dart';

/// The whole roster, including missing and absent students.
class StudentsPane extends StatelessWidget {
  const StudentsPane({super.key, required this.report, required this.sessionId, required this.onChanged});

  final Map<String, Object?> report;
  final int sessionId;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final services = Services.of(context);
    final workspace = services.workspace;
    final session = services.store.session(sessionId)!;
    final roster = ((services.store.getClass((session['class_name'] as String?) ?? '')?['students'] as List?) ?? const []).cast<Map<String, Object?>>();
    final scored = (report['students']! as List).cast<Map<String, Object?>>();
    final missing = workspace.missingRosterStudents(sessionId);
    final rows = <Map<String, Object?>>[
      for (final student in roster)
        if (!scored.any((s) => sameStudentId(s['student_id'], student['id'])))
          {
            'student_name': student['name'], 'student_id': student['id'],
            '_canAbsent': missing.any((s) => sameStudentId(s['id'], student['id'])),
            '_absent': missing.any((s) => sameStudentId(s['id'], student['id']) && s['absent'] == true),
          },
      ...scored,
    ]..sort((a, b) => '${a['student_name'] ?? ''}'.toLowerCase().compareTo('${b['student_name'] ?? ''}'.toLowerCase()));
    return SectionCard(
      title: 'Student scores',
      subtitle: 'Full class roster, by name. Mark missing students absent for this exam, or add their sheets.',
      child: rows.isEmpty
          ? const EmptyState(title: 'No student sheets')
          : SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: const [
                  DataColumn(label: Text('Edit')),
                  DataColumn(label: Text('Student')),
                  DataColumn(label: Text('ID')),
                  DataColumn(label: Text('Absent')),
                  DataColumn(label: Text('Score'), numeric: true),
                  DataColumn(label: Text('%'), numeric: true),
                  DataColumn(label: Text('Blank'), numeric: true),
                  DataColumn(label: Text('Multiple'), numeric: true),
                  DataColumn(label: Text('Missed questions')),
                ],
                rows: [
                  for (final row in rows)
                    () {
                      final score = row['score'] as Map<String, Object?>?;
                      if (score == null) {
                        final canAbsent = row['_canAbsent'] == true;
                        final absent = row['_absent'] == true;
                        return DataRow(cells: [
                          const DataCell(Text('—')),
                          DataCell(Text('${row['student_name']}')),
                          DataCell(Text('${row['student_id']}')),
                          DataCell(Checkbox(
                            key: ValueKey('roster-absent-${row['student_id']}'),
                            value: absent,
                            onChanged: canAbsent ? (value) {
                              workspace.setStudentAbsent(sessionId, row['student_id'] as String, value == true);
                              onChanged();
                            } : null,
                          )),
                          DataCell(Text(absent ? 'Absent' : canAbsent ? 'Missing score' : 'Needs review')),
                          const DataCell(Text('—')),
                          const DataCell(Text('—')),
                          const DataCell(Text('—')),
                          const DataCell(Text('—')),
                        ]);
                      }
                      final missed = (score['missed_questions']! as List).join(', ');
                      final id = row['student_id'] ?? row['student_id_read'];
                      return DataRow(cells: [
                        DataCell(IconButton(
                          tooltip: 'Edit student on sheet ${row["page"]}',
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () async {
                            final saved = await editStudentIdentity(context, sessionId: sessionId, report: report, student: row);
                            if (saved) onChanged();
                          },
                        )),
                        DataCell(Text((row['student_name'] as String?)?.isNotEmpty == true
                            ? row['student_name']! as String
                            : '—')),
                        DataCell(Text(id == null || id == '' ? '—' : '$id')),
                        const DataCell(Text('—')),
                        DataCell(Text('${score['correct']} / ${score['total']}')),
                        DataCell(Text('${score['percentage']}%')),
                        DataCell(Text('${score['blank']}')),
                        DataCell(Text('${score['multiple']}')),
                        DataCell(ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 360),
                          child: Text(missed.isEmpty ? '—' : missed),
                        )),
                      ]);
                    }(),
                ],
              ),
            ),
    );
  }
}

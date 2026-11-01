import 'package:flutter/material.dart';

import '../../ui/widgets.dart';
import 'student_identity_dialog.dart';

/// Every student's score, best first.
class StudentsPane extends StatelessWidget {
  const StudentsPane({super.key, required this.report, required this.sessionId, required this.onChanged});

  final Map<String, Object?> report;
  final int sessionId;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final rows = [...(report['students']! as List).cast<Map<String, Object?>>()]
      ..sort((a, b) => ((b['score']! as Map)['percentage']! as num)
          .compareTo((a['score']! as Map)['percentage']! as num));
    return SectionCard(
      title: 'Student scores',
      subtitle: 'Best first. Missed questions are listed so you know where to reteach.',
      child: rows.isEmpty
          ? const EmptyState(title: 'No student sheets')
          : SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: const [
                  DataColumn(label: Text('Edit')),
                  DataColumn(label: Text('Student')),
                  DataColumn(label: Text('ID')),
                  DataColumn(label: Text('Score'), numeric: true),
                  DataColumn(label: Text('%'), numeric: true),
                  DataColumn(label: Text('Blank'), numeric: true),
                  DataColumn(label: Text('Multiple'), numeric: true),
                  DataColumn(label: Text('Missed questions')),
                ],
                rows: [
                  for (final row in rows)
                    () {
                      final score = row['score']! as Map<String, Object?>;
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

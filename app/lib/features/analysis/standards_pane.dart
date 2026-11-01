import 'package:flutter/material.dart';

import '../../ui/widgets.dart';

/// Results grouped by standard and by section, for a test scored from a test
/// package: the class as a whole, then each student, so reteach groups can be
/// read straight off the table.
class StandardsPane extends StatelessWidget {
  const StandardsPane({super.key, required this.report});

  final Map<String, Object?> report;

  @override
  Widget build(BuildContext context) {
    final standards = ((report['standards'] as Map?) ?? const {}).cast<String, Object?>();
    final sections = ((report['sections'] as Map?) ?? const {}).cast<String, Object?>();
    final students = ((report['students'] as List?) ?? const []).cast<Map<String, Object?>>();
    final named = [for (final name in standards.keys) if (name != '(none)') name];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (named.isNotEmpty)
          SectionCard(
            title: 'By standard',
            subtitle: 'Percent of the class correct on each standard, across every version.',
            child: _GroupTable(groups: standards, label: 'Standard'),
          ),
        if (sections.keys.any((name) => name != '(none)'))
          SectionCard(
            title: 'By section',
            child: _GroupTable(groups: sections, label: 'Section'),
          ),
        if (named.isNotEmpty)
          SectionCard(
            title: 'Each student, by standard',
            subtitle: 'Items right out of items on that standard. Use it to group students for reteaching.',
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: [
                  const DataColumn(label: Text('Student')),
                  const DataColumn(label: Text('Version')),
                  for (final name in named) DataColumn(label: Text(name), numeric: true),
                ],
                rows: [
                  for (final s in students)
                    DataRow(cells: [
                      DataCell(Text(_who(s))),
                      DataCell(Text('${s['version'] ?? '—'}')),
                      for (final name in named)
                        DataCell(Text(_fraction((s['standards'] as Map?)?[name]))),
                    ]),
                ],
              ),
            ),
          ),
        if (named.isEmpty && !sections.keys.any((name) => name != '(none)'))
          const SectionCard(
            title: 'Standards',
            child: EmptyState(
              title: 'No standards in this test package',
              message: 'Add a Standard and a Section to each item in the package to see results grouped here.',
              icon: Icons.category_outlined,
            ),
          ),
      ],
    );
  }

  static String _who(Map<String, Object?> s) {
    final name = s['student_name'] as String?;
    if (name != null && name.isNotEmpty) return name;
    return '${s['student_id'] ?? 'Sheet ${s['page']}'}';
  }

  static String _fraction(Object? cell) {
    if (cell is! Map) return '—';
    return '${cell['correct']}/${cell['items']}';
  }
}

class _GroupTable extends StatelessWidget {
  const _GroupTable({required this.groups, required this.label});

  final Map<String, Object?> groups;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        for (final entry in groups.entries)
          if (entry.key != '(none)')
            Semantics(
              label: '$label ${entry.key}, ${(entry.value as Map)['items']} items, '
                  '${(entry.value as Map)['class_pct']} percent correct',
              excludeSemantics: true,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    SizedBox(width: 160, child: Text(entry.key, overflow: TextOverflow.ellipsis)),
                    SizedBox(width: 70, child: Text('${(entry.value as Map)['items']} items')),
                    Expanded(
                      child: LinearProgressIndicator(
                        value: (((entry.value as Map)['class_pct'] as num?) ?? 0) / 100,
                        minHeight: 10,
                        borderRadius: BorderRadius.circular(5),
                        backgroundColor: scheme.surfaceContainerHighest,
                      ),
                    ),
                    SizedBox(
                      width: 64,
                      child: Text(
                        '${((entry.value as Map)['class_pct'] as num?)?.toStringAsFixed(1)}%',
                        textAlign: TextAlign.end,
                      ),
                    ),
                  ],
                ),
              ),
            ),
      ],
    );
  }
}

/// The answers of a test scored from a test package, item by item. They come
/// from the package (or each version's key sheet), so they are changed there.
class PackageKeyPane extends StatelessWidget {
  const PackageKeyPane({super.key, required this.report});

  final Map<String, Object?> report;

  @override
  Widget build(BuildContext context) {
    final exam = (report['exam']! as Map).cast<String, Object?>();
    final versions = [for (final v in (exam['versions'] as List? ?? const [])) '$v'];
    final items = ((exam['items'] as List?) ?? const []).cast<Map<String, Object?>>();
    final mismatches = ((report['key_mismatches'] as List?) ?? const []).cast<Map<String, Object?>>();
    return SectionCard(
      title: 'Answer key',
      subtitle: exam['key_source'] == 'package'
          ? 'From the test package. To change an answer, correct the package and read the batch again.'
          : 'From each version’s key sheet. To change an answer, fix the key sheet and read the batch again.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final m in mismatches)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Version ${m['version']} question ${m['question']} (${m['item']}): the package says '
                '${m['package']}, the key sheet on page ${m['key_page']} shows ${m['key_sheet']}. '
                'Scored with the package.',
                style: TextStyle(color: Tone.warn.foreground(Theme.of(context).colorScheme)),
              ),
            ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: [
                const DataColumn(label: Text('Item')),
                const DataColumn(label: Text('Section')),
                const DataColumn(label: Text('Standard')),
                for (final v in versions) ...[
                  DataColumn(label: Text('V$v #'), numeric: true),
                  DataColumn(label: Text('V$v answer')),
                ],
              ],
              rows: [
                for (final item in items)
                  DataRow(cells: [
                    DataCell(Text('${item['item']}')),
                    DataCell(Text('${item['section'] ?? ''}')),
                    DataCell(Text('${item['standard'] ?? ''}')),
                    for (final v in versions) ...[
                      DataCell(Text('${(item['questions'] as Map)[v]}')),
                      DataCell(Text('${(item['answers'] as Map)[v]}')),
                    ],
                  ]),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

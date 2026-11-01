import 'package:datalink_core/datalink_core.dart';
import 'package:flutter/material.dart';

import '../../ui/widgets.dart';

/// Per-question results with filters, plus the full statistical table.
class ItemsPane extends StatefulWidget {
  const ItemsPane({super.key, required this.report});

  final Map<String, Object?> report;

  @override
  State<ItemsPane> createState() => _ItemsPaneState();
}

class _ItemsPaneState extends State<ItemsPane> {
  ItemFilter _filter = ItemFilter.all;
  bool _diagnostics = false;

  static const _filterLabels = {
    ItemFilter.all: 'All items',
    ItemFilter.priority: 'Priority',
    ItemFilter.developing: 'Developing',
    ItemFilter.secure: 'Secure',
    ItemFilter.flagged: 'Flagged',
  };

  @override
  Widget build(BuildContext context) {
    final all = (widget.report['items']! as List).cast<Map<String, Object?>>();
    final items = filterItems(all, _filter);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionCard(
          title: 'Item performance',
          subtitle: 'Sorted by question. Priority means fewer than 60% got it right.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SegmentedButton<ItemFilter>(
                showSelectedIcon: false,
                segments: [
                  for (final entry in _filterLabels.entries)
                    ButtonSegment(value: entry.key, label: Text(entry.value)),
                ],
                selected: {_filter},
                onSelectionChanged: (s) => setState(() => _filter = s.first),
              ),
              const SizedBox(height: 12),
              if (items.isEmpty)
                const EmptyState(title: 'No items match this filter')
              else
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columns: const [
                      DataColumn(label: Text('Item'), numeric: true),
                      DataColumn(label: Text('Key')),
                      DataColumn(label: Text('% correct')),
                      DataColumn(label: Text('Correct'), numeric: true),
                      DataColumn(label: Text('Most common wrong')),
                      DataColumn(label: Text('Status')),
                    ],
                    rows: [for (final item in items) _row(context, item)],
                  ),
                ),
            ],
          ),
        ),
        SectionCard(
          title: 'Full statistical diagnostics',
          subtitle: 'Difficulty, point biserial, upper−lower discrimination, and the answer spread.',
          trailing: TextButton(
            onPressed: () => setState(() => _diagnostics = !_diagnostics),
            child: Text(_diagnostics ? 'Hide diagnostics' : 'Show diagnostics'),
          ),
          child: _diagnostics ? _Diagnostics(items: all) : const SizedBox.shrink(),
        ),
      ],
    );
  }

  DataRow _row(BuildContext context, Map<String, Object?> item) {
    final percent = (item['percent_correct']! as num).toDouble();
    final status = itemStatus(percent);
    final tone = switch (status) {
      ItemStatus.priority => Tone.bad,
      ItemStatus.developing => Tone.warn,
      ItemStatus.secure => Tone.good,
    };
    final flagged = (item['flags']! as List).isNotEmpty;
    return DataRow(cells: [
      DataCell(Text('${item['question']}', style: const TextStyle(fontWeight: FontWeight.w600))),
      DataCell(Text('${item['correct_answer']}')),
      DataCell(
        Semantics(
          label: '${percent.toStringAsFixed(1)} percent correct',
          excludeSemantics: true,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 120,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: (percent / 100).clamp(0, 1),
                    minHeight: 8,
                    color: tone.foreground(Theme.of(context).colorScheme),
                    backgroundColor: tone.background(Theme.of(context).colorScheme),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text('${percent.toStringAsFixed(1)}%'),
            ],
          ),
        ),
      ),
      DataCell(Text('${item['n_correct']}')),
      DataCell(Text(item['most_common_wrong'] as String? ?? '—')),
      DataCell(Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusPill(text: status.label, tone: tone),
          if (flagged) ...[const SizedBox(width: 6), const StatusPill(text: 'Flagged')],
        ],
      )),
    ]);
  }
}

class _Diagnostics extends StatelessWidget {
  const _Diagnostics({required this.items});

  final List<Map<String, Object?>> items;

  static const _choices = ['A', 'B', 'C', 'D', 'E', 'BLANK', 'MULTIPLE'];

  @override
  Widget build(BuildContext context) {
    String number(Object? value) => value == null ? '—' : '$value';
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columnSpacing: 16,
        columns: [
          const DataColumn(label: Text('Item'), numeric: true),
          const DataColumn(label: Text('Key')),
          const DataColumn(label: Text('% correct'), numeric: true),
          const DataColumn(label: Text('Difficulty'), numeric: true),
          const DataColumn(label: Text('Point biserial'), numeric: true),
          const DataColumn(label: Text('Upper−lower'), numeric: true),
          for (final c in _choices)
            DataColumn(label: Text('${c == 'MULTIPLE' ? 'Mult' : c} %'), numeric: true),
          const DataColumn(label: Text('Flags')),
        ],
        rows: [
          for (final item in items)
            DataRow(cells: [
              DataCell(Text('${item['question']}')),
              DataCell(Text('${item['correct_answer']}')),
              DataCell(Text((item['percent_correct']! as num).toStringAsFixed(1))),
              DataCell(Text(number(item['difficulty']))),
              DataCell(Text(number(item['point_biserial']))),
              DataCell(Text(number(item['upper_lower_discrimination']))),
              for (final c in _choices)
                // A test in several versions has no combined A-E spread: a
                // letter means a different choice on each version.
                DataCell(Text('${(((item['distribution'] as Map?)?[c]) as Map?)?['pct'] ?? '—'}')),
              DataCell(Text((item['flags']! as List).isEmpty ? '—' : (item['flags']! as List).join(', '))),
            ]),
        ],
      ),
    );
  }
}

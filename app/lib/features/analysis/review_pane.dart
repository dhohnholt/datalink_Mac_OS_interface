import 'package:datalink_core/datalink_core.dart';
import 'package:flutter/material.dart';

import '../../app/scope.dart';
import '../../ui/widgets.dart';
import '../paper/page_viewer.dart';
import 'review_edit.dart';

/// Everything a person has to decide about a scored test: sheets with no ID,
/// doubtful marks, disagreements with the scanner's own marking.
class ReviewPane extends StatefulWidget {
  const ReviewPane({
    super.key,
    required this.sessionId,
    required this.report,
    required this.onChanged,
  });

  final int sessionId;
  final Map<String, Object?> report;
  final VoidCallback onChanged;

  @override
  State<ReviewPane> createState() => _ReviewPaneState();
}

class _ReviewPaneState extends State<ReviewPane> {
  late final List<ReviewRow> _rows = reviewProblems(widget.report);
  final Map<int, ReviewSheetEdit> _edits = {};
  final Set<String> _checked = {};
  final Map<String, String> _fixes = {};
  bool _built = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_built) return;
    _built = true;
    final book = Services.of(context).classBook;
    final className = (widget.report['class_name'] as String?) ?? '';
    final roster = book.studentsOf(className);
    for (final row in _rows) {
      if (row.wholeTest || _edits.containsKey(row.sheet)) continue;
      final student = row.student ?? const <String, Object?>{};
      _edits[row.sheet] = ReviewSheetEdit(
        sheet: row.sheet,
        // The ID the reader saw, even when it was not sure enough to use it.
        originalId: ((student['student_id'] ?? student['student_id_read']) as String?) ?? '',
        originalName: (student['student_name'] as String?) ?? '',
        roster: roster,
        className: className,
      );
    }
  }

  @override
  void dispose() {
    for (final edit in _edits.values) {
      edit.dispose();
    }
    super.dispose();
  }

  Map<int, List<String>> get _answers => {
        for (final s in (widget.report['students']! as List).cast<Map<String, Object?>>())
          s['page']! as int: [
            for (final a in (s['answers']! as List).cast<Map<String, Object?>>()) a['response']! as String,
          ],
      };

  Future<void> _apply() async {
    final services = Services.of(context);
    final rowByKey = {for (final r in _rows) r.key: r};
    final submission = collectReview(
      sheets: _edits.values.toList(),
      checked: _checked,
      fixes: [
        for (final entry in _fixes.entries)
          if (rowByKey[entry.key] case final row?)
            (sheet: row.sheet, question: row.question!, value: entry.value, rowKey: row.key),
      ],
      answers: _answers,
    );
    if (submission.problem != null) {
      showToast(context, submission.problem!);
      return;
    }
    if (submission.isEmpty) {
      showToast(context, 'Change something, or tick what you have checked');
      return;
    }
    try {
      final result = services.workspace.correct(
        widget.sessionId,
        submission.corrections,
        dismiss: submission.dismiss,
      );
      if (!mounted) return;
      final parts = [
        if ((result['applied'] as int) > 0) '${result['applied']} correction(s)',
        if ((result['dismissed'] as int) > 0) '${result['dismissed']} checked off',
      ];
      showToast(context, 'Applied ${parts.isEmpty ? 'nothing' : parts.join(' · ')}');
      widget.onChanged();
    } on DataLinkError catch (error) {
      showToast(context, error.message);
    } on StoreError catch (error) {
      showToast(context, error.message);
    }
  }

  void _viewSheet(int sheet) {
    final picture = Services.of(context).workspace.sessionPage(widget.sessionId, sheet);
    showPagePicture(
      context,
      title: 'Sheet $sheet',
      note: 'The sheet as it was scanned. Read the name off the paper, then correct the ID behind this.',
      picture: picture,
    );
  }

  void _restore() {
    final restored = Services.of(context).workspace.restoreReviews(widget.sessionId);
    showToast(context, 'Brought back $restored item(s)');
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final dismissed = (widget.report['dismissed_count'] as int?) ?? 0;
    final allChecked = _rows.isNotEmpty && _rows.every((r) => _checked.contains(r.key));

    final restoreLine = dismissed == 0
        ? null
        : Row(children: [
            Text('$dismissed item${dismissed == 1 ? '' : 's'} checked off and hidden. '),
            TextButton(onPressed: _restore, child: const Text('Show them again')),
          ]);

    if (_rows.isEmpty) {
      return SectionCard(
        title: 'Review',
        child: Column(children: [
          const EmptyState(
            title: 'Nothing to review',
            message: 'Every sheet has an ID and clear marks.',
            icon: Icons.check_circle_outline,
          ),
          ?restoreLine,
        ]),
      );
    }

    final groups = <int, List<ReviewRow>>{};
    for (final row in _rows) {
      groups.putIfAbsent(row.sheet, () => []).add(row);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionCard(
          title: 'Review',
          subtitle: 'Fix what is wrong, or tick a row once you have checked it. Nothing changes until you apply.',
          trailing: Wrap(
            spacing: 8,
            children: [
              OutlinedButton(
                onPressed: () => setState(() {
                  if (allChecked) {
                    _checked.clear();
                  } else {
                    _checked.addAll(_rows.map((r) => r.key));
                  }
                }),
                child: Text(allChecked ? 'Untick all' : 'Mark all checked'),
              ),
              FilledButton(onPressed: _apply, child: const Text('Apply corrections')),
            ],
          ),
          child: restoreLine ?? const SizedBox.shrink(),
        ),
        for (final entry in groups.entries) _SheetGroup(
          sheet: entry.key,
          onViewSheet: widget.report['has_pages'] == true ? _viewSheet : null,
          rows: entry.value,
          edit: _edits[entry.key],
          checked: _checked,
          fixes: _fixes,
          onToggle: (key, on) => setState(() => on ? _checked.add(key) : _checked.remove(key)),
          onFix: (key, value) => setState(() => value.isEmpty ? _fixes.remove(key) : _fixes[key] = value),
        ),
      ],
    );
  }
}

class _SheetGroup extends StatelessWidget {
  const _SheetGroup({
    required this.sheet,
    required this.rows,
    required this.edit,
    required this.checked,
    required this.fixes,
    required this.onToggle,
    required this.onFix,
    this.onViewSheet,
  });

  /// Opens the scan of a sheet; null when this test has no page pictures.
  final void Function(int sheet)? onViewSheet;
  final int sheet;
  final List<ReviewRow> rows;
  final ReviewSheetEdit? edit;
  final Set<String> checked;
  final Map<String, String> fixes;
  final void Function(String key, bool on) onToggle;
  final void Function(String key, String value) onFix;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: sheet == 0 ? 'Note about the whole test' : 'Sheet $sheet',
      child: Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (edit != null)
                ListenableBuilder(
                  listenable: edit!,
                  builder: (context, _) => _StudentFields(sheet: sheet, edit: edit!, onView: onViewSheet),
                )
              else
                Text('This test', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              for (final row in rows) _ProblemRow(
                row: row,
                checked: checked.contains(row.key),
                fix: fixes[row.key] ?? '',
                onToggle: (on) => onToggle(row.key, on),
                onFix: (value) => onFix(row.key, value),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StudentFields extends StatelessWidget {
  const _StudentFields({required this.sheet, required this.edit, this.onView});

  final void Function(int sheet)? onView;
  final int sheet;
  final ReviewSheetEdit edit;

  @override
  Widget build(BuildContext context) {
    // Rebuilt from the edit each time; the controllers follow the model so the
    // boxes always show what Apply would send.
    return Wrap(
      spacing: 16,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (onView == null)
          Text('Sheet $sheet', style: Theme.of(context).textTheme.titleSmall)
        else
          TextButton.icon(
            icon: const Icon(Icons.image_outlined, size: 18),
            onPressed: () => onView!(sheet),
            label: Text('Sheet $sheet'),
          ),
        SizedBox(
          width: 170,
          child: _Field(
            label: 'Student ID',
            value: edit.id,
            keyboardType: TextInputType.number,
            onChanged: edit.setId,
            onLeave: () => edit.setId(edit.id, leaving: true),
          ),
        ),
        if (edit.hasRoster)
          SizedBox(
            width: 240,
            child: Semantics(
              label: 'Student',
              child: DropdownButton<int>(
                isExpanded: true,
                value: edit.chosenIndex,
                items: [
                  DropdownMenuItem(
                    value: -1,
                    child: Text(
                      edit.name.isNotEmpty && edit.chosenIndex < 0
                          ? '${edit.name} — not on this roster'
                          : 'Choose a student…',
                    ),
                  ),
                  for (var i = 0; i < edit.roster.length; i++)
                    DropdownMenuItem(value: i, child: Text(edit.roster[i].name)),
                ],
                onChanged: (index) => edit.choose(index ?? -1),
              ),
            ),
          ),
        if (!edit.nameBoxHidden)
          SizedBox(
            width: 240,
            child: _Field(
              label: edit.namePlaceholder,
              value: edit.name,
              onChanged: edit.setName,
            ),
          ),
      ],
    );
  }
}

/// A text field whose content follows a model value without fighting typing.
class _Field extends StatefulWidget {
  const _Field({
    required this.label,
    required this.value,
    required this.onChanged,
    this.onLeave,
    this.keyboardType,
  });

  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final VoidCallback? onLeave;
  final TextInputType? keyboardType;

  @override
  State<_Field> createState() => _FieldState();
}

class _FieldState extends State<_Field> {
  late final TextEditingController _controller = TextEditingController(text: widget.value);
  late final FocusNode _focus = FocusNode()
    ..addListener(() {
      if (!_focus.hasFocus) widget.onLeave?.call();
    });

  @override
  void didUpdateWidget(_Field old) {
    super.didUpdateWidget(old);
    // The model changed the value (a roster fill), not the typist.
    if (widget.value != _controller.text) {
      _controller.value = TextEditingValue(
        text: widget.value,
        selection: TextSelection.collapsed(offset: widget.value.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: _focus,
      keyboardType: widget.keyboardType,
      decoration: InputDecoration(labelText: widget.label),
      onChanged: widget.onChanged,
    );
  }
}

class _ProblemRow extends StatelessWidget {
  const _ProblemRow({
    required this.row,
    required this.checked,
    required this.fix,
    required this.onToggle,
    required this.onFix,
  });

  final ReviewRow row;
  final bool checked;
  final String fix;
  final ValueChanged<bool> onToggle;
  final ValueChanged<String> onFix;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: Text(row.problem)),
          const SizedBox(width: 12),
          Semantics(
            label: 'Read as ${row.read}',
            excludeSemantics: true,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(row.read, style: const TextStyle(fontFamily: 'Menlo')),
            ),
          ),
          const SizedBox(width: 12),
          if (row.kind == ReviewKind.answer)
            Semantics(
              label: 'Correct question ${row.question}',
              child: DropdownButton<String>(
                value: fix,
                items: const [
                  DropdownMenuItem(value: '', child: Text('Keep as read')),
                  DropdownMenuItem(value: 'A', child: Text('A')),
                  DropdownMenuItem(value: 'B', child: Text('B')),
                  DropdownMenuItem(value: 'C', child: Text('C')),
                  DropdownMenuItem(value: 'D', child: Text('D')),
                  DropdownMenuItem(value: 'E', child: Text('E')),
                  DropdownMenuItem(value: 'BLANK', child: Text('Blank')),
                ],
                onChanged: (value) => onFix(value ?? ''),
              ),
            )
          else
            const SizedBox(width: 120),
          const SizedBox(width: 8),
          Semantics(
            label: 'Checked: clear this from the list',
            child: Checkbox(value: checked, onChanged: (on) => onToggle(on ?? false)),
          ),
        ],
      ),
    );
  }
}

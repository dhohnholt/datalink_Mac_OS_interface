import 'package:datalink_core/datalink_core.dart';
import 'package:flutter/material.dart';

import '../../app/scope.dart';
import '../../ui/widgets.dart';

/// Edit the answer key. Saving rescores every sheet against it.
class KeyPane extends StatefulWidget {
  const KeyPane({
    super.key,
    required this.sessionId,
    required this.report,
    required this.onChanged,
  });

  final int sessionId;
  final Map<String, Object?> report;
  final VoidCallback onChanged;

  @override
  State<KeyPane> createState() => _KeyPaneState();
}

class _KeyPaneState extends State<KeyPane> {
  late final List<String> _original = [
    for (final entry in ((widget.report['exam']! as Map)['answer_key']! as List).cast<Map<String, Object?>>())
      entry['answer']! as String,
  ];
  late List<String> _edited = List.of(_original);

  int get _changes {
    var count = 0;
    for (var i = 0; i < _original.length; i++) {
      if (_edited[i] != _original[i]) count++;
    }
    return count;
  }

  Future<void> _save() async {
    final services = Services.of(context);
    final ok = await confirmDialog(
      context,
      title: 'Save answer key',
      message: 'Save this answer key? Every sheet in the test is rescored against it.',
      confirmLabel: 'Save',
    );
    if (!ok || !mounted) return;
    final keyPage = (widget.report['exam']! as Map)['key_page']! as int;
    try {
      final result = services.workspace.correct(widget.sessionId, [
        {'number': keyPage, 'responses': _edited},
      ]);
      if (!mounted) return;
      showToast(
        context,
        (result['applied'] as int) > 0 ? 'Answer key saved and sheets rescored' : 'No change was made',
      );
      widget.onChanged();
    } on DataLinkError catch (error) {
      showToast(context, error.message);
    } on StoreError catch (error) {
      showToast(context, error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final changes = _changes;
    return SectionCard(
      title: 'Answer key',
      subtitle: 'Fix a question the scanner read wrongly. Changed answers are marked.',
      trailing: Wrap(
        spacing: 8,
        children: [
          TextButton(
            onPressed: changes == 0 ? null : () => setState(() => _edited = List.of(_original)),
            child: const Text('Undo changes'),
          ),
          FilledButton(
            onPressed: changes == 0 ? null : _save,
            child: const Text('Save answer key'),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (changes > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  '$changes answer${changes == 1 ? '' : 's'} changed. '
                  'Saving rescores every sheet in this test.',
                  style: TextStyle(color: Tone.warn.foreground(Theme.of(context).colorScheme)),
                ),
              ),
            ),
          Wrap(
            spacing: 24,
            runSpacing: 8,
            children: [
              for (var i = 0; i < _edited.length; i++)
                SizedBox(
                  width: MediaQuery.textScalerOf(context).scale(340),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 36,
                        child: Text(
                          '${i + 1}',
                          textAlign: TextAlign.end,
                          style: TextStyle(
                            fontWeight: _edited[i] != _original[i] ? FontWeight.w800 : null,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      for (final letter in const ['A', 'B', 'C', 'D', 'E'])
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Semantics(
                            label: 'Question ${i + 1}, answer $letter'
                                '${_edited[i] != _original[i] && _edited[i] == letter ? ', changed' : ''}',
                            excludeSemantics: true,
                            selected: _edited[i] == letter,
                            button: true,
                            child: ChoiceChip(
                              label: Text(letter),
                              selected: _edited[i] == letter,
                              visualDensity: VisualDensity.compact,
                              onSelected: (_) => setState(() => _edited[i] = letter),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

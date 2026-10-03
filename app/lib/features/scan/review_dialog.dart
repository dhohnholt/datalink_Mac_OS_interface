import 'package:datalink_core/datalink_core.dart';
import 'package:flutter/material.dart';

import 'scan_model.dart';

/// The dialog a sheet opens when it needs a human: a student ID to confirm or
/// type, and a choice for each question that had more than one mark.
class ReviewDialog extends StatefulWidget {
  const ReviewDialog({super.key, required this.model});

  final ScanModel model;

  @override
  State<ReviewDialog> createState() => _ReviewDialogState();
}

class _ReviewDialogState extends State<ReviewDialog> {
  // Captured once: the sheet this dialog was opened for.
  late final Map<String, Object?> _review = widget.model.pendingReview!;
  late final ReviewPlan _plan = widget.model.pendingPlan!;
  late final TextEditingController _id = TextEditingController(text: _plan.idPrefill);
  late final TextEditingController _name = TextEditingController(text: _plan.namePrefill);
  late final Map<int, String> _choices = {
    for (final item in _ambiguities) item['question']! as int: (item['options']! as List).first as String,
  };
  String? _error;
  bool _closed = false;

  /// Which roster student this sheet belongs to: an index into the roster,
  /// [_other] to type an ID instead, or null when nothing is chosen yet.
  static const int _other = -1;
  late final List<RosterStudent> _roster = widget.model.walk.students;
  late int? _pick = _initialPick();

  /// With a class roster, the student is chosen from it and the ID follows,
  /// rather than typed. Without one, or for a sheet that only needs its
  /// doubtful marks settled, nothing changes.
  bool get _picking => _roster.isNotEmpty && _plan.needsStudentId;

  int? _initialPick() {
    if (_roster.isEmpty || !_plan.needsStudentId) return null;
    final walk = widget.model.walk;
    if (_plan.idPrefill.isNotEmpty) {
      final index = walk.indexForId(_plan.idPrefill);
      return index >= 0 ? index : _other;
    }
    // Nothing was read from the sheet: the student the screen said was next.
    return walk.current == null ? null : walk.index;
  }

  /// Nothing came off the sheet to confirm, so the question is simply who.
  bool get _asksWho => _picking && _plan.idPrefill.isEmpty;

  List<Map<String, Object?>> get _ambiguities =>
      ((_review['ambiguities'] as List?) ?? const []).cast<Map<String, Object?>>();

  @override
  void initState() {
    super.initState();
    widget.model.addListener(_watch);
  }

  /// If the sheet was dealt with some other way (the session ended, the scanner
  /// was unplugged), there is nothing left to decide here.
  void _watch() {
    if (!_closed && widget.model.pendingReview?['id'] != _review['id']) _close();
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    widget.model.removeListener(_watch);
    _id.dispose();
    _name.dispose();
    super.dispose();
  }

  void _save() {
    var id = _id.text;
    var name = _name.text;
    if (_picking && _pick != _other) {
      final pick = _pick;
      if (pick == null) {
        setState(() => _error = 'Choose the student, or "Not on the roster" to type an ID.');
        return;
      }
      id = _roster[pick].id;
      name = _roster[pick].name;
    }
    final error = widget.model.resolve(
      {for (final e in _choices.entries) '${e.key}': e.value},
      id,
      name,
    );
    if (error == null) {
      _close();
    } else {
      setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    return AlertDialog(
      title: Semantics(header: true, child: Text(_asksWho ? 'Which student is this?' : plan.title)),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _asksWho
                    ? 'Choose the student this sheet belongs to; their ID is filled in for you. '
                        'If they are not on the roster, choose that and type the ID.'
                    : plan.intro,
              ),
              const SizedBox(height: 12),
              if (_picking) ...[
                DropdownButtonFormField<int>(
                  isExpanded: true,
                  initialValue: _pick,
                  decoration: const InputDecoration(labelText: 'Student'),
                  items: [
                    for (var i = 0; i < _roster.length; i++)
                      DropdownMenuItem(value: i, child: Text('${_roster[i].name} · ${_roster[i].id}')),
                    const DropdownMenuItem(value: _other, child: Text('Not on the roster — type an ID')),
                  ],
                  onChanged: (value) => setState(() {
                    _pick = value;
                    _error = null;
                  }),
                ),
                const SizedBox(height: 12),
              ],
              if (plan.needsStudentId && (!_picking || _pick == _other)) ...[
                TextField(
                  controller: _id,
                  autofocus: !_picking,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Student ID'),
                  onSubmitted: (_) => _save(),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Student name (optional)'),
                  onSubmitted: (_) => _save(),
                ),
                const SizedBox(height: 12),
              ],
              for (final item in _ambiguities) _question(context, item),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          autofocus: _picking && _pick != null && _pick != _other,
          onPressed: _save,
          child: const Text('Save correction'),
        ),
      ],
    );
  }

  Widget _question(BuildContext context, Map<String, Object?> item) {
    final question = item['question']! as int;
    final value = item['value']! as String;
    final options = (item['options']! as List).cast<String>();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Semantics(
        container: true,
        label: 'Question $question was read as $value',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text.rich(TextSpan(children: [
              TextSpan(text: 'Question $question was read as '),
              TextSpan(text: value, style: const TextStyle(fontWeight: FontWeight.w700)),
            ])),
            RadioGroup<String>(
              groupValue: _choices[question],
              onChanged: (v) => setState(() => _choices[question] = v ?? ''),
              child: Wrap(
                spacing: 8,
                children: [
                  for (final option in options) _radio(option, option),
                  _radio('', 'Blank'),
                  _radio(value, 'Keep $value'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _radio(String value, String label) => SizedBox(
        width: 120,
        child: RadioListTile<String>(
          dense: true,
          contentPadding: EdgeInsets.zero,
          value: value,
          title: Text(label),
        ),
      );
}

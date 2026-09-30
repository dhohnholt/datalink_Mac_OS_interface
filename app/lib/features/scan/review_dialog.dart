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
    final error = widget.model.resolve(
      {for (final e in _choices.entries) '${e.key}': e.value},
      _id.text,
      _name.text,
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
      title: Semantics(header: true, child: Text(plan.title)),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(plan.intro),
              const SizedBox(height: 12),
              if (plan.needsStudentId) ...[
                TextField(
                  controller: _id,
                  autofocus: true,
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
        FilledButton(onPressed: _save, child: const Text('Save correction')),
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

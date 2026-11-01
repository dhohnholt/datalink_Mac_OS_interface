import 'dart:async';
import 'dart:convert';

import 'package:datalink_core/datalink_core.dart';
import 'package:flutter/material.dart';

import '../../app/navigation.dart';
import '../../app/scope.dart';
import '../../ui/widgets.dart';
import 'upload_choices.dart';

/// Send one scored run to the teacher's own site.
class UploadPane extends StatefulWidget {
  const UploadPane({super.key, required this.sessionId});

  final int sessionId;

  @override
  State<UploadPane> createState() => _UploadPaneState();
}

class _UploadPaneState extends State<UploadPane> {
  UploadChoices? _choices;
  String? _error;
  Map<String, Object?>? _success;
  bool _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final connection = Services.of(context).connection;
    unawaited(connection.ensureLoaded());
    final destinations = connection.destinations;
    final choices = _choices;
    if (choices == null) {
      _choices = UploadChoices(destinations);
    } else {
      choices.update(destinations);
    }
  }

  // Re-reading an unchanged analysis regenerates created_at. Compare its
  // content (including the stable audit run ID), not the time it was rendered.
  String _analysisFingerprint(Map<String, Object?> report) =>
      jsonEncode(Map<String, Object?>.from(report)..remove('created_at'));

  Future<void> _upload({bool replacement = false}) async {
    if (_busy) return;
    final services = Services.of(context);
    final destination = _choices!.selected;
    if (destination == null) return;
    final sessionId = widget.sessionId;
    final report = services.workspace.scoredSession(sessionId).report;
    final fingerprint = _analysisFingerprint(report);
    final candidate = _choices!.draft?['run_id'];
    setState(() {
      _busy = true;
      _error = null;
      _success = null;
    });
    try {
      String? replace;
      if (replacement) {
        await services.connection.refresh();
        if (!mounted) return;
        final fresh = UploadChoices([
          for (final d in services.connection.destinations)
            if (d['exam_id'] == destination['exam_id']) d,
        ]);
        final run = fresh.draft;
        if (candidate == null || run?['run_id'] != candidate) {
          throw const UploadError('The draft is no longer available for replacement. Use Add results to upload additional students.');
        }
        final ok = await confirmDialog(
          context,
          title: 'Replace draft results',
          message: 'Replace the current unfinalized results for ${destination['exam_title']}? '
              "The corrected scan becomes the test's current draft.",
          confirmLabel: 'Replace',
        );
        if (!ok || !mounted) return;
        replace = candidate as String;
      }
      if (widget.sessionId != sessionId || _choices!.exam != destination['exam_id'] ||
          _analysisFingerprint(services.workspace.scoredSession(sessionId).report) != fingerprint) {
        throw const UploadError('The selected test or analysis changed. Choose an action again.');
      }
      final result = await services.connection.upload(
        destination['exam_id']! as String,
        report,
        '${destination['test_code'] ?? ''}',
        replaceRunId: replace,
      );
      result['exam_title'] = destination['exam_title'];
      if (!mounted) return;
      setState(() => _success = result);
      showToast(
        context,
        result['status'] == 'updated' ? 'Updated draft results on your site' : 'Uploaded to your site',
      );
      await services.connection.refreshQuietly();
    } on UploadError catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on AnalysisError catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    final connection = Services.of(context).connection;
    setState(() => _busy = true);
    try {
      final count = await connection.refresh();
      if (mounted) showToast(context, '$count test(s) available');
    } on UploadError catch (error) {
      if (mounted) showToast(context, error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final connection = Services.of(context).connection;
    return ListenableBuilder(
      listenable: connection,
      builder: (context, _) {
        final choices = _choices!..update(connection.destinations);
        return SectionCard(
          title: 'Send to your site',
          subtitle: 'Uploads this scored run to the address set in Settings. What happens to it '
              'afterwards is up to your site.',
          trailing: connection.connected
              ? Wrap(spacing: 8, children: [
                  OutlinedButton(
                    onPressed: _busy ? null : _refresh,
                    child: const Text('Refresh tests'),
                  ),
                  OutlinedButton(
                    onPressed: _busy || choices.draft == null ? null : () => _upload(replacement: true),
                    child: const Text('Replace draft results'),
                  ),
                  FilledButton(
                    onPressed: _busy || choices.selected == null ? null : () => _upload(),
                    child: Text(_busy ? 'Uploading…' : 'Add results'),
                  ),
                ])
              : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              !connection.loaded
                  ? const EmptyState(title: 'Checking your connection…', icon: Icons.cloud_queue_outlined)
                  : connection.connected
                      ? _picker(context, choices)
                      : _notConnected(context),
              // Outside the picker, so it survives the pane switching to "not
              // connected" when the site withdraws the token mid-upload.
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _notConnected(BuildContext context) => Column(
        children: [
          const EmptyState(
            title: 'DataLink is not connected to a site yet.',
            message: 'Connect one in Settings, then come back to send this test.',
            icon: Icons.cloud_off_outlined,
          ),
          FilledButton(
            onPressed: () => Nav.read(context).show(AppView.settings),
            child: const Text('Open Settings'),
          ),
        ],
      );

  Widget _picker(BuildContext context, UploadChoices choices) {
    Widget dropdown(String label, String? value, List<(String, String)> options, ValueChanged<String> onChanged) =>
        SizedBox(
          width: 260,
          child: DropdownButtonFormField<String>(
            // Rebuilt when the options change so the shown value is never one
            // that is no longer on offer.
            key: ValueKey('$label-$value-${options.length}'),
            isExpanded: true,
            initialValue: value,
            decoration: InputDecoration(labelText: label),
            items: [for (final (v, text) in options) DropdownMenuItem(value: v, child: Text(text, overflow: TextOverflow.ellipsis))],
            onChanged: (v) {
              if (v != null && !_busy) setState(() { onChanged(v); _success = null; _error = null; });
            },
          ),
        );

    final draftDetail = choices.draftDetail;
    final success = _success;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(spacing: 16, runSpacing: 16, children: [
          dropdown('Course', choices.course, choices.courses, choices.chooseCourse),
          dropdown('Section', choices.section, choices.sections, choices.chooseSection),
          dropdown('Unit', choices.unit, choices.units, choices.chooseUnit),
          dropdown('Test', choices.exam, choices.tests, choices.chooseTest),
        ]),
        const SizedBox(height: 12),
        Text(choices.detail),
        if (draftDetail != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Card(
              color: Theme.of(context).colorScheme.tertiaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(draftDetail),
                    const SizedBox(height: 4),
                    const Text('Upload another scan to add missing student scores or update existing scores for matching students.'),
                  ],
                ),
              ),
            ),
          ),
        if (success != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Semantics(
              liveRegion: true,
              container: true,
              child: Row(children: [
                const Icon(Icons.check_circle_outline, color: Color(0xFF2E9E57)),
                const SizedBox(width: 8),
                Expanded(child: Text('Sent. Run ${success['run_id'] ?? '—'}')),
                if ('${success['review_url'] ?? ''}'.isNotEmpty)
                  TextButton(
                    onPressed: () => Services.of(context).actions.openUrl('${success['review_url']}'),
                    child: const Text('Open on your site'),
                  ),
              ]),
            ),
          ),
      ],
    );
  }
}

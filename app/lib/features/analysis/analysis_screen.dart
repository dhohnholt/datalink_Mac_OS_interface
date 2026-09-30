import 'package:datalink_core/datalink_core.dart';
import 'package:flutter/material.dart';

import '../../app/navigation.dart';
import '../../app/scope.dart';
import '../../ui/widgets.dart';
import 'items_pane.dart';
import 'key_pane.dart';
import 'review_pane.dart';
import 'students_pane.dart';
import 'upload_pane.dart';

/// Item analysis for one saved test: how the class did, who needs a second
/// look, and the answer key.
class AnalysisScreen extends StatefulWidget {
  const AnalysisScreen({super.key});

  @override
  State<AnalysisScreen> createState() => _AnalysisScreenState();
}

class _AnalysisScreenState extends State<AnalysisScreen> {
  Map<String, Object?>? _report;
  String? _error;
  int? _loadedFor;
  bool _loaded = false;

  /// Bumped each time the report is re-read, so a pane built from the old one
  /// starts afresh instead of keeping rows that no longer exist.
  int _revision = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final id = Nav.of(context).sessionId;
    if (!_loaded || id != _loadedFor) _load(id);
  }

  void _load(int? id) {
    _loaded = true;
    _loadedFor = id;
    _report = null;
    _error = null;
    if (id == null) return;
    final workspace = Services.of(context).workspace;
    try {
      _report = workspace.analysisReport(id);
    } on AnalysisError catch (error) {
      _error = error.message;
    } on NotFoundError {
      _error = 'That test is no longer saved.';
    }
  }

  /// Re-read the report after something changed it.
  void reload() => setState(() {
        _revision++;
        _load(_loadedFor);
      });

  @override
  Widget build(BuildContext context) {
    final services = Services.of(context);
    final nav = Nav.of(context);
    final sessions = services.store.listSessions();
    final report = _report;
    final reviewCount = report == null ? 0 : (report['review_items']! as List).length;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        SectionCard(
          title: 'Item analysis',
          subtitle: 'How the class did on each question, and which sheets need a second look.',
          trailing: Wrap(
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Semantics(
                label: 'Test',
                child: DropdownButton<int?>(
                  value: sessions.any((s) => s['id'] == nav.sessionId) ? nav.sessionId : null,
                  hint: const Text('Choose a test…'),
                  items: [
                    for (final s in sessions)
                      DropdownMenuItem(
                        value: s['id']! as int,
                        child: Text(
                          '${(s['name'] as String?)?.isNotEmpty == true ? s['name'] : 'Untitled'} · '
                          '${formatTimestamp(s['started_at'] as String?)} · ${s['scan_count']} sheets',
                        ),
                      ),
                  ],
                  onChanged: (id) {
                    if (id == null) {
                      nav.clearSession();
                    } else {
                      nav.openSession(id, view: AppView.analysis);
                    }
                  },
                ),
              ),
              if (report != null)
                OutlinedButton.icon(
                  onPressed: _download,
                  icon: const Icon(Icons.download),
                  label: const Text('Download JSON'),
                ),
            ],
          ),
          child: const SizedBox.shrink(),
        ),
        if (report == null && _error == null)
          const EmptyState(
            title: 'No test selected',
            message: 'Choose a test above, or open one from Sessions.',
            icon: Icons.insights_outlined,
          ),
        if (_error != null) _ErrorBanner(message: _error!),
        if (report != null) ...[
          _Summary(report: report),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<AnalysisPane>(
              showSelectedIcon: false,
              segments: [
                const ButtonSegment(value: AnalysisPane.items, label: Text('Item analysis')),
                const ButtonSegment(value: AnalysisPane.students, label: Text('Student scores')),
                ButtonSegment(
                  value: AnalysisPane.review,
                  label: Semantics(
                    label: reviewCount == 0
                        ? 'Review'
                        : 'Review, $reviewCount item${reviewCount == 1 ? '' : 's'} to review',
                    excludeSemantics: true,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Text('Review'),
                      ExcludeSemantics(
                        child: CountBadge(count: reviewCount, noun: 'item to review'),
                      ),
                    ]),
                  ),
                ),
                const ButtonSegment(value: AnalysisPane.key, label: Text('Answer key')),
                const ButtonSegment(value: AnalysisPane.upload, label: Text('Send to your site')),
              ],
              selected: {nav.pane},
              onSelectionChanged: (selection) => nav.showPane(selection.first),
            ),
          ),
          const SizedBox(height: 16),
          switch (nav.pane) {
            AnalysisPane.students => StudentsPane(report: report),
            AnalysisPane.review => ReviewPane(
                key: ValueKey('review-$_loadedFor-$_revision'),
                sessionId: _loadedFor!,
                report: report,
                onChanged: reload,
              ),
            AnalysisPane.key => KeyPane(
                key: ValueKey('key-$_loadedFor-$_revision'),
                sessionId: _loadedFor!,
                report: report,
                onChanged: reload,
              ),
            AnalysisPane.upload => UploadPane(sessionId: _loadedFor!),
            _ => ItemsPane(report: report),
          },
        ],
      ],
    );
  }

  Future<void> _download() async {
    final services = Services.of(context);
    final id = _loadedFor;
    if (id == null) return;
    try {
      final export = services.workspace.analysisDownload(id);
      final path = await services.actions.saveText(
        suggestedName: export.filename,
        text: export.json,
        extension: 'json',
      );
      if (path != null && mounted) showToast(context, 'Saved ${export.filename}');
    } on AnalysisError catch (error) {
      if (mounted) showToast(context, error.message);
    }
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      container: true,
      label: 'This test cannot be scored. $message',
      child: Card(
        color: scheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(child: Icon(Icons.error_outline, color: scheme.onErrorContainer)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'This test cannot be scored',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(color: scheme.onErrorContainer),
                    ),
                    const SizedBox(height: 4),
                    Text(message, style: TextStyle(color: scheme.onErrorContainer)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.report});

  final Map<String, Object?> report;

  @override
  Widget build(BuildContext context) {
    final summary = report['summary']! as Map<String, Object?>;
    final items = (report['items']! as List).cast<Map<String, Object?>>();
    final counts = itemCounts(items);
    final callout = priorityCallout(items);
    final mean = summary['mean_percentage'];
    final kr20 = summary['kr20'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MetricRow(
          tiles: [
            MetricTile(label: 'Students', value: '${summary['student_count']}'),
            MetricTile(label: 'Average', value: mean == null ? '—' : '$mean%'),
            MetricTile(label: 'KR-20', value: kr20 == null ? '—' : '$kr20'),
            MetricTile(label: 'To review', value: '${(report['review_items']! as List).length}'),
          ],
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            StatusPill(text: '${counts.priority} Priority', tone: Tone.bad),
            StatusPill(text: '${counts.developing} Developing', tone: Tone.warn),
            StatusPill(text: '${counts.secure} Secure', tone: Tone.good),
            StatusPill(text: '${counts.flagged} Flagged'),
          ],
        ),
        if (callout != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Semantics(
              container: true,
              child: Card(
                color: Theme.of(context).colorScheme.tertiaryContainer,
                child: Padding(padding: const EdgeInsets.all(12), child: Text(callout)),
              ),
            ),
          ),
      ],
    );
  }
}


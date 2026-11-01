import 'package:datalink_core/datalink_core.dart';
import 'package:flutter/material.dart';

import '../../app/navigation.dart';
import '../../app/scope.dart';
import '../../ui/widgets.dart';
import '../scan/question_count_dialog.dart';
import 'items_pane.dart';
import 'key_pane.dart';
import 'review_pane.dart';
import 'standards_pane.dart';
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
  Map<String, Object?>? _countSuggestion;
  String? _error;
  int? _loadedFor;
  bool _loaded = false;

  /// Bumped each time the report is re-read, so a pane built from the old one
  /// starts afresh instead of keeping rows that no longer exist.
  int _revision = 0;
  bool _showAllScans = false;

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
    _countSuggestion = null;
    if (id == null) return;
    final services = Services.of(context);
    final workspace = services.workspace;
    try {
      _report = workspace.analysisReport(id);
    } on AnalysisError catch (error) {
      _error = error.message;
    } on NotFoundError {
      _error = 'That test is no longer saved.';
      return;
    }
    // A test still being scanned is handled where it is scanned; changing it
    // from here would leave the scanner counting the old number.
    if (services.scanner.currentSessionId != id) {
      _countSuggestion = workspace.questionCountSuggestion(id);
    }
  }

  Future<void> _useFewerQuestions() async {
    final suggestion = _countSuggestion;
    final id = _loadedFor;
    if (suggestion == null || id == null) return;
    final suggested = suggestion['suggested']! as int;
    final marks = suggestion['marks']! as int;
    final sheets = suggestion['sheets']! as int;
    // Nothing is lost when no student marked past the new end, so no need to
    // make a person confirm what only restates the banner.
    if (marks > 0) {
      final ok = await questionCountDialog(
        context,
        current: suggestion['current']! as int,
        suggested: suggested,
        sheets: sheets,
        marks: marks,
      );
      if (!ok || !mounted) return;
    }
    try {
      Services.of(context).workspace.useFewerQuestions(id, suggested);
    } on DataLinkError catch (error) {
      if (mounted) showToast(context, error.message);
      return;
    }
    if (!mounted) return;
    showToast(context, 'Now scored out of $suggested questions');
    reload();
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
                child: SizedBox(
                  width: 440,
                  child: DropdownButton<int?>(
                  isExpanded: true,
                  value: sessions.any((s) => s['id'] == nav.sessionId) ? nav.sessionId : null,
                  hint: const Text('Choose a test…'),
                  items: [
                    for (final s in sessions)
                      DropdownMenuItem(
                        value: s['id']! as int,
                        child: Text(
                          '${(s['name'] as String?)?.isNotEmpty == true ? s['name'] : 'Untitled'} · '
                          '${formatTimestamp(s['started_at'] as String?)} · ${s['scan_count']} sheets',
                          overflow: TextOverflow.ellipsis,
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
        if (_countSuggestion != null)
          _CountBanner(suggestion: _countSuggestion!, onUse: _useFewerQuestions),
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
          // The button sits beside the panes when there is room and drops to
          // its own line when there is not, so it never covers a pane. The
          // five panes alone do not fit at large text sizes; they scroll
          // rather than clip.
          Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<AnalysisPane>(
              showSelectedIcon: false,
              segments: [
                const ButtonSegment(value: AnalysisPane.items, label: Text('Item analysis')),
                const ButtonSegment(value: AnalysisPane.students, label: Text('Student scores')),
                // Only a test scored from a test package has standards.
                if (report['standards'] != null)
                  const ButtonSegment(value: AnalysisPane.standards, label: Text('Standards')),
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
                // A test scored in several versions cannot be sent yet (the site
                // takes one key per test); it shows Standards in its place, which
                // also keeps the panes within the window.
                if (report['standards'] == null)
                  const ButtonSegment(value: AnalysisPane.upload, label: Text('Send to your site')),
              ],
              selected: {_shownPane(nav.pane, report)},
              onSelectionChanged: (selection) => nav.showPane(selection.first),
              ),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.document_scanner_outlined),
              label: Text(_showAllScans && nav.pane == AnalysisPane.review ? 'Hide scans' : 'Review all scans'),
              onPressed: () {
                setState(() => _showAllScans = nav.pane == AnalysisPane.review ? !_showAllScans : true);
                nav.showPane(AnalysisPane.review);
              },
            ),
          ]),
          const SizedBox(height: 16),
          switch (_shownPane(nav.pane, report)) {
            AnalysisPane.students => StudentsPane(report: report, sessionId: _loadedFor!, onChanged: reload),
            AnalysisPane.review => ReviewPane(
                key: ValueKey('review-$_loadedFor-$_revision'),
                showAllScans: _showAllScans,
                sessionId: _loadedFor!,
                report: report,
                onChanged: reload,
              ),
            AnalysisPane.standards when report['standards'] != null => StandardsPane(report: report),
            AnalysisPane.key when (report['exam'] as Map?)?['form'] == 'package' => PackageKeyPane(report: report),
            AnalysisPane.key => KeyPane(
                key: ValueKey('key-$_loadedFor-$_revision'),
                sessionId: _loadedFor!,
                report: report,
                onChanged: reload,
              ),
            AnalysisPane.upload when (report['exam'] as Map?)?['form'] == 'package' => const SectionCard(
                title: 'Send to your site',
                child: Text(
                  'A test scored in several versions at once cannot be sent to your site yet: the site takes one '
                  'answer key per test. Use Download JSON for the combined results, or read each version on its own '
                  'to send it.',
                ),
              ),
            AnalysisPane.upload => UploadPane(sessionId: _loadedFor!),
            _ => ItemsPane(report: report),
          },
        ],
      ],
    );
  }

  /// Standards exist only for a test scored from a test package, and such a
  /// test has no Send pane; opening one test while on the other's pane shows
  /// the nearest pane it has.
  AnalysisPane _shownPane(AnalysisPane pane, Map<String, Object?> report) {
    final package = report['standards'] != null;
    if (pane == AnalysisPane.standards && !package) return AnalysisPane.items;
    if (pane == AnalysisPane.upload && package) return AnalysisPane.standards;
    return pane;
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

/// The test was saved with more questions than its answer key has.
class _CountBanner extends StatelessWidget {
  const _CountBanner({required this.suggestion, required this.onUse});

  final Map<String, Object?> suggestion;
  final VoidCallback onUse;

  @override
  Widget build(BuildContext context) {
    final current = suggestion['current']! as int;
    final suggested = suggestion['suggested']! as int;
    final theme = Theme.of(context);
    final text = 'The answer key has answers for questions 1 to $suggested and none after that, '
        'but this test is set to $current questions. If it is a $suggested-question test, score it out of $suggested.';
    return Semantics(
      container: true,
      liveRegion: true,
      label: 'This looks like a $suggested-question test. $text',
      child: Card(
        color: Tone.warn.background(theme.colorScheme),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(child: Icon(Tone.warn.icon, color: Tone.warn.foreground(theme.colorScheme))),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('This looks like a $suggested-question test', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(text),
                    const SizedBox(height: 12),
                    FilledButton(onPressed: onUse, child: Text('Score out of $suggested')),
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


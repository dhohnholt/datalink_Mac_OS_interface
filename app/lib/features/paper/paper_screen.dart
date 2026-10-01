import 'package:datalink_core/datalink_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/navigation.dart';
import '../../app/scope.dart';
import '../../ui/widgets.dart';
import 'page_viewer.dart';
import 'paper_model.dart';

/// Reading a PDF batch of answer sheets, for when the DataLink is not at hand.
class PaperScreen extends StatefulWidget {
  const PaperScreen({super.key});

  @override
  State<PaperScreen> createState() => _PaperScreenState();
}

class _PaperScreenState extends State<PaperScreen> {
  final _name = TextEditingController();
  final _keyPage = TextEditingController(text: '1');
  final _questions = TextEditingController(text: '$maxQuestions');
  final Map<int, String> _keyChoices = {};
  String? _synced;
  PaperModel? _model;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final model = Services.of(context).paper;
    if (!identical(model, _model)) {
      _model?.removeListener(_changed);
      _model = model..addListener(_changed);
      _changed();
    }
  }

  /// A file chosen from the menu, or a name defaulted from it, changes the
  /// model behind the fields' backs; bring the fields along.
  void _changed() {
    final model = _model!;
    final marker = '${model.file?.path}|${model.name}|${model.keyPage}|${model.questions}';
    if (marker == _synced) return;
    _synced = marker;
    if (_name.text != model.name) _name.text = model.name;
    if (_keyPage.text != '${model.keyPage}') _keyPage.text = '${model.keyPage}';
    if (_questions.text != '${model.questions}') _questions.text = '${model.questions}';
    if (model.keyReview == null) _keyChoices.clear();
  }

  @override
  void dispose() {
    _model?.removeListener(_changed);
    _name.dispose();
    _keyPage.dispose();
    _questions.dispose();
    super.dispose();
  }

  Future<void> _choose(PaperModel model) async {
    final path = await Services.of(context).actions.pickPdf();
    if (path != null) model.setPdf(path);
  }

  Future<void> _run(PaperModel model, {Map<int, String> overrides = const {}}) async {
    model.setName(_name.text);
    await model.run(keyOverrides: overrides);
    if (!mounted) return;
    if (model.phase == PaperPhase.done && model.takePurgeOffer()) {
      final ok = await confirmDialog(
        context,
        title: 'Empty the page cache?',
        message: 'The scanned page cache is now ${_size(model.cacheBytes)}, over the '
            '${_size(cacheWarnBytes)} mark.\n\nOnly the page pictures go — your sessions, scores '
            'and item analyses are kept.',
        confirmLabel: 'Empty it',
      );
      if (ok && mounted) {
        final freed = model.purge();
        showToast(context, 'Freed ${_size(freed)}');
      }
    }
  }

  Future<void> _purge(PaperModel model) async {
    final ok = await confirmDialog(
      context,
      title: 'Empty the page cache?',
      message: 'Only the page pictures go. Saved sessions, scores and item analyses are untouched, '
          'but the sheet pictures in Review will be gone.',
      confirmLabel: 'Empty the cache',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final freed = model.purge();
    showToast(context, 'Freed ${_size(freed)}');
  }

  @override
  Widget build(BuildContext context) {
    final model = Services.of(context).paper;
    final book = model.classBook;
    return ListenableBuilder(
      listenable: Listenable.merge([model, book]),
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(24),
        children: [
          SectionCard(
            title: 'Read a paper batch',
            subtitle:
                'Scan the sheets on any document scanner, then read the PDF here — for when the DataLink is not available.',
            trailing: OutlinedButton.icon(
              icon: const Icon(Icons.folder_open),
              onPressed: model.busy ? null : () => _choose(model),
              label: const Text('Choose PDF…'),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (model.showSetup) _setup(context, model),
                if (model.busy) _progress(context, model),
                if (model.phase == PaperPhase.failed && model.keyReview == null && model.error != null)
                  _message(context, model.error!, Tone.bad),
                if (model.file == null && model.error != null && model.phase != PaperPhase.failed)
                  _message(context, model.error!, Tone.bad),
                if (model.keyReview != null) _keyFix(context, model),
                if (model.phase == PaperPhase.done) _done(context, model),
              ],
            ),
          ),
          SectionCard(
            title: 'Scanned page cache',
            subtitle: model.cacheBytes == 0
                ? 'Nothing cached yet.'
                : '${_size(model.cacheBytes)} of page pictures from ${model.cacheBatches} '
                    'batch${model.cacheBatches == 1 ? '' : 'es'}',
            trailing: OutlinedButton(
              onPressed: model.cacheBytes == 0 ? null : () => _purge(model),
              child: const Text('Empty the cache'),
            ),
            child: Text(
              'A small picture of each page is kept so a sheet can be looked at later, when its ID or a '
              'name has to be corrected by eye. Emptying the cache removes only those pictures — saved '
              'sessions, scores and item analyses are untouched.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _setup(BuildContext context, PaperModel model) {
    final names = [for (final c in model.classBook.classes) c['name']! as String];
    final keyValue = int.tryParse(_keyPage.text);
    final keyError = keyValue == null || keyValue < 1 || keyValue > model.pageCount
        ? 'Choose a page from 1 to ${model.pageCount}'
        : null;
    final questionValue = int.tryParse(_questions.text);
    final questionError =
        questionValue == null || questionValue < 1 || questionValue > maxQuestions ? '1 to $maxQuestions' : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _callout(context, model.fileLine, Tone.neutral, icon: Icons.picture_as_pdf_outlined),
        const SizedBox(height: 16),
        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            SizedBox(
              width: 300,
              child: TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Test name', hintText: 'Unit 2 Exam — 5th Period'),
                onChanged: model.setName,
              ),
            ),
            SizedBox(
              width: 220,
              child: DropdownButtonFormField<String>(
                isExpanded: true,
                key: ValueKey('paper-class-${model.className}-${names.length}'),
                initialValue: names.contains(model.className) ? model.className : '',
                decoration: const InputDecoration(labelText: 'Class'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('No roster')),
                  for (final name in names) DropdownMenuItem(value: name, child: Text(name)),
                ],
                onChanged: (value) => model.setClass(value ?? ''),
              ),
            ),
            SizedBox(
              width: 200,
              child: TextField(
                controller: _keyPage,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: 'Answer key page',
                  errorText: keyError,
                  suffixIcon: _hint(
                    'About the answer key page',
                    'The page number of the marked key, counting every page in the PDF including blank backs.',
                  ),
                ),
                onChanged: (value) {
                  final page = int.tryParse(value);
                  if (page != null) model.setKeyPage(page);
                },
              ),
            ),
            SizedBox(
              width: 180,
              child: TextField(
                controller: _questions,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(labelText: 'Questions per form', errorText: questionError),
                onChanged: (value) {
                  final count = int.tryParse(value);
                  if (count != null) model.setQuestions(count);
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: model.canRun ? () => _run(model) : null,
          child: const Text('Read the sheets'),
        ),
      ],
    );
  }

  Widget _hint(String label, String text) => Semantics(
        label: '$label. $text',
        excludeSemantics: true,
        child: Tooltip(
          message: text,
          triggerMode: TooltipTriggerMode.tap,
          showDuration: const Duration(seconds: 8),
          child: const Icon(Icons.info_outline, size: 18),
        ),
      );

  Widget _progress(BuildContext context, PaperModel model) {
    final percent = (model.progress * 100).round();
    return Semantics(
      container: true,
      liveRegion: true,
      label: '${model.message} $percent percent',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(model.message),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: model.progress, minHeight: 8, borderRadius: BorderRadius.circular(4)),
        ],
      ),
    );
  }

  Widget _message(BuildContext context, String text, Tone tone) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: _callout(context, text, tone),
      );

  Widget _callout(BuildContext context, String text, Tone tone, {IconData? icon}) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      liveRegion: tone != Tone.neutral,
      label: text,
      excludeSemantics: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: tone.background(scheme), borderRadius: BorderRadius.circular(8)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon ?? tone.icon, size: 20, color: tone.foreground(scheme)),
            const SizedBox(width: 8),
            Expanded(child: Text(text)),
          ],
        ),
      ),
    );
  }

  // The reader will not score anything against a key it could not read, which
  // is right, but refusing without a way forward would strand the batch. This
  // asks for the answers it could not settle and reads again.
  Widget _keyFix(BuildContext context, PaperModel model) {
    final review = model.keyReview!;
    final keyPage = review['key_page']! as int;
    final unresolved = (review['unresolved']! as Map<String, Object?>).map((q, seen) => MapEntry(int.parse(q), '$seen'));
    final questions = unresolved.keys.toList()..sort();
    final answered = questions.every(_keyChoices.containsKey);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Semantics(
        container: true,
        label: 'The answer key needs a hand',
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Tone.warn.background(theme.colorScheme),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Semantics(header: true, child: Text('The answer key needs a hand', style: theme.textTheme.titleSmall)),
                        const SizedBox(height: 4),
                        Text(
                          'Nothing can be scored until the key is settled. The key was read from page $keyPage; '
                          '${questions.length == 1 ? 'one question' : '${questions.length} questions'} could not be '
                          'made out. Look at the sheet and say what each should be.',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton(
                    onPressed: () => showPagePicture(
                      context,
                      title: 'Answer key — page $keyPage',
                      note: 'The key sheet as it was scanned. Read off the answers it could not settle, '
                          'then choose them behind this.',
                      picture: model.pagePicture(keyPage),
                    ),
                    child: const Text('Look at the key sheet'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              for (final question in questions)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 16,
                    runSpacing: 4,
                    children: [
                      SizedBox(
                        width: 260,
                        child: Text.rich(TextSpan(children: [
                          TextSpan(text: 'Question $question', style: const TextStyle(fontWeight: FontWeight.w600)),
                          TextSpan(text: '  ${_seen(unresolved[question]!)}', style: theme.textTheme.bodySmall),
                        ])),
                      ),
                      SegmentedButton<String>(
                        showSelectedIcon: false,
                        emptySelectionAllowed: true,
                        segments: [
                          for (final letter in const ['A', 'B', 'C', 'D', 'E'])
                            ButtonSegment(value: letter, label: Text(letter), tooltip: 'Question $question is $letter'),
                        ],
                        selected: {if (_keyChoices[question] != null) _keyChoices[question]!},
                        onSelectionChanged: (selection) => setState(() {
                          if (selection.isEmpty) {
                            _keyChoices.remove(question);
                          } else {
                            _keyChoices[question] = selection.first;
                          }
                        }),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                children: [
                  FilledButton(
                    // A partial set would only be refused again by the reader.
                    onPressed: answered
                        ? () {
                            final choices = {for (final q in questions) q: _keyChoices[q]!};
                            _keyChoices.clear();
                            _run(model, overrides: choices);
                          }
                        : null,
                    child: const Text('Use these and read the batch'),
                  ),
                  TextButton(
                    onPressed: () {
                      _keyChoices.clear();
                      model.startOver();
                    },
                    child: const Text('Start over'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _seen(String read) => read.isEmpty || read == 'BLANK'
      ? 'nothing marked on the key'
      : read == 'MULTIPLE'
          ? 'two or more marks on the key'
          : 'read as $read';

  Widget _done(BuildContext context, PaperModel model) {
    final nav = Nav.read(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _callout(
            context,
            '${model.message}. They are saved as a session, ready to review and send to your site.',
            Tone.good,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            children: [
              FilledButton(
                onPressed: model.sessionId == null
                    ? null
                    : () => nav.openSession(model.sessionId!, view: AppView.analysis),
                child: const Text('Open the item analysis'),
              ),
              OutlinedButton(onPressed: model.readAnother, child: const Text('Read another batch')),
            ],
          ),
        ],
      ),
    );
  }
}

String _size(int bytes) {
  final mb = bytes / 1048576;
  if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} GB';
  if (mb >= 1) return '${mb.toStringAsFixed(0)} MB';
  return '${(bytes / 1024).toStringAsFixed(0)} KB';
}

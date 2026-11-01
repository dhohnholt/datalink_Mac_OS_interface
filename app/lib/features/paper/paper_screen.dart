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
  final _questions = TextEditingController(text: '$accuScanQuestions');
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
    model.setFiles(await Services.of(context).actions.pickScanFiles());
  }

  Future<void> _copyPrompt() async {
    await Clipboard.setData(const ClipboardData(text: testPackagePrompt));
    if (mounted) showToast(context, 'Prompt copied');
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

  Future<void> _saveSheet(String asset, String name, String what) async {
    final data = await rootBundle.load('assets/$asset');
    if (!mounted) return;
    final path = await Services.of(context).actions.saveBytes(
      suggestedName: name,
      bytes: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      extension: 'pdf',
      mimeType: 'application/pdf',
    );
    if (path != null && mounted) showToast(context, 'Saved the $what');
  }

  Widget _sheetRow(String label, String detail, VoidCallback onPressed) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SizedBox(
              width: 280,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.download_outlined),
                onPressed: onPressed,
                label: Text(label),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(child: Text(detail, style: Theme.of(context).textTheme.bodySmall)),
          ],
        ),
      );

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
                if (model.packageError != null) _message(context, model.packageError!, Tone.bad),
                if (model.countSuggestion != null) _countFix(context, model),
                if (model.keyReview != null) _keyFix(context, model),
                if (model.phase == PaperPhase.done) _done(context, model),
              ],
            ),
          ),
          SectionCard(
            title: 'Several versions of one test',
            subtitle: 'Score every version in one run, with results by item, section and standard.',
            trailing: FilledButton.tonalIcon(
              icon: const Icon(Icons.copy_outlined),
              onPressed: _copyPrompt,
              label: const Text('Copy prompt'),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Give the copied prompt to the AI assistant that writes your test versions. It produces a test '
                  'package: a CSV listing each item, its section and standard, its number on each version and its '
                  'answer there. Choose the scanned PDF and the package together with Choose PDF… (⌘-click both). '
                  'Students bubble their version; key sheets need not be scanned, and any that are get checked '
                  'against the package.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text('Show the prompt'),
                  children: [
                    SelectableText(
                      testPackagePrompt,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'Menlo'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          SectionCard(
            title: 'Printable answer sheets',
            subtitle: 'Print on plain US Letter paper when you run out of forms.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Each has lines for name, course, test name and period, a bubbled version (1–4) and student '
                  'ID, and an ANSWER KEY bubble for the key sheet. Print at Actual Size, not Fit to Page, and set '
                  'the number of copies in the print dialog. Pencil or dark blue or black pen both read; keep the '
                  'black corner squares and the strip along the bottom free of marks.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                _sheetRow(
                  'Save answer sheet…',
                  '75 questions, A–E.',
                  () => _saveSheet('answer_sheet_75.pdf', 'Answer Sheet (75 questions).pdf', 'answer sheet'),
                ),
                _sheetRow(
                  'Save 50 + matching sheet…',
                  '50 questions, A–E, and a 15-term matching column (51–65, A–O). Rows left blank on the key '
                      'are not scored.',
                  () => _saveSheet('answer_sheet_50_matching.pdf', 'Answer Sheet (50 questions + matching).pdf',
                      '50 + matching sheet'),
                ),
                _sheetRow(
                  'Save vocabulary quiz sheet…',
                  '8 matching (A–J), 8 words in context (A–D), 4 select all that apply (A–E).',
                  () => _saveSheet('vocabulary_quiz_sheet.pdf', 'Vocabulary Quiz Sheet.pdf', 'vocabulary quiz sheet'),
                ),
                _sheetRow(
                  'Save vocabulary teacher guide…',
                  'How to write a quiz for the vocabulary sheet and make its key, with a sample.',
                  () => _saveSheet('vocabulary_quiz_teacher_guide.pdf', 'Vocabulary Quiz Teacher Guide.pdf',
                      'teacher guide'),
                ),
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
    final keyError = !model.findKey && (keyValue == null || keyValue < 1 || keyValue > model.pageCount)
        ? 'Choose a page from 1 to ${model.pageCount}'
        : null;
    final questionValue = int.tryParse(_questions.text);
    final questionError =
        questionValue == null || questionValue < 1 || questionValue > maxQuestions ? '1 to $maxQuestions' : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _callout(context, model.fileLine, Tone.neutral, icon: Icons.picture_as_pdf_outlined),
        if (model.package != null) ...[
          const SizedBox(height: 8),
          _callout(context, 'Test package: ${model.packageLine}', Tone.neutral, icon: Icons.table_chart_outlined),
          TextButton(onPressed: model.clearPackage, child: const Text('Remove the test package')),
        ],
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
              width: 280,
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
            if (model.package == null) SizedBox(
              width: 200,
              child: TextField(
                controller: _keyPage,
                enabled: !model.findKey,
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
            if (model.package == null) SizedBox(
              width: 160,
              child: DropdownButtonFormField<String>(
                isExpanded: true,
                key: ValueKey('paper-version-${model.version}'),
                initialValue: model.version ?? '',
                decoration: InputDecoration(
                  labelText: 'Version',
                  suffixIcon: _hint(
                    'About the version',
                    'For the printable sheet. When the PDF holds keys for more than one version, choose one '
                        'and read the batch once for each.',
                  ),
                ),
                items: [
                  const DropdownMenuItem(value: '', child: Text('Any')),
                  for (final v in sheetVersions.split('')) DropdownMenuItem(value: v, child: Text('Version $v')),
                ],
                onChanged: (value) => model.setVersion(value == null || value.isEmpty ? null : value),
              ),
            ),
            if (model.package == null) SizedBox(
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
        const SizedBox(height: 8),
        if (model.package == null) CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: model.findKey,
          onChanged: (value) => model.setFindKey(value ?? false),
          title: const Text('Find the key sheet by its ANSWER KEY bubble'),
          subtitle: const Text('For the printable 75-question sheet. The key can be anywhere in the stack.'),
        ),
        const SizedBox(height: 8),
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

  // The count is typed before the sheets are read, and it is easy to leave at
  // the form's 50 for a shorter test. The key sheet, read on its own first,
  // shows it: answers through question 30 and nothing after.
  Widget _countFix(BuildContext context, PaperModel model) {
    final suggestion = model.countSuggestion!;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Semantics(
        container: true,
        liveRegion: true,
        label: 'This looks like a ${suggestion.suggested}-question test',
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
              Semantics(
                header: true,
                child: Text('This looks like a ${suggestion.suggested}-question test', style: theme.textTheme.titleSmall),
              ),
              const SizedBox(height: 4),
              Text(
                'The answer key (page ${suggestion.keyPage}) has answers for questions 1 to ${suggestion.suggested} '
                'and none after that, but the batch is set to ${suggestion.current} questions. Scored out of '
                '${suggestion.current}, every percentage would be wrong.',
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  FilledButton(
                    autofocus: true,
                    onPressed: () {
                      model.useSuggestedCount();
                      _run(model);
                    },
                    child: Text('Read as ${suggestion.suggested} questions'),
                  ),
                  OutlinedButton(
                    onPressed: () {
                      model.keepQuestionCount();
                      _run(model);
                    },
                    child: Text('Keep ${suggestion.current} questions'),
                  ),
                ],
              ),
            ],
          ),
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
          if (model.notScored.isNotEmpty) ...[
            const SizedBox(height: 8),
            _callout(
              context,
              'Not scored: ${[for (final n in model.notScored) 'page ${n['page']} (${n['reason']})'].join(', ')}. '
              'Bubble a version on those sheets, scan them and read them again with the package.',
              Tone.warn,
            ),
          ],
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

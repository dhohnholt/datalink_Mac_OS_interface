import 'package:datalink_core/datalink_core.dart';
import 'package:flutter/material.dart';

import '../../app/scope.dart';
import '../paper/page_viewer.dart';
import 'review_edit.dart';
import 'review_pane.dart';

/// Correct any scored sheet, even when the reader did not flag it for review.
Future<bool> editStudentIdentity(
  BuildContext context, {
  required int sessionId,
  required Map<String, Object?> report,
  required Map<String, Object?> student,
  bool reviewAnswers = false,
}) async {
  final services = Services.of(context);
  final className = (report['class_name'] as String?) ?? '';
  var sheet = student['page']! as int;
  var edit = ReviewSheetEdit(
    sheet: sheet,
    originalId:
        (student['student_id'] ?? student['student_id_read'] ?? '') as String,
    originalName: (student['student_name'] as String?) ?? '',
    roster: services.classBook.studentsOf(className),
    className: className,
  );
  // A double mark keeps its letters ("AC"), so saving the sheet cannot turn
  // a right answer to a multiple-answer question into an unreadable "*".
  var originalAnswers = [
    for (final answer
        in (student['answers'] as List? ?? const [])
            .cast<Map<String, Object?>>())
      (answer['marks'] ?? answer['response'])! as String,
  ];
  var answers = List<String>.of(originalAnswers);
  var picture = reviewAnswers && report['has_pages'] == true
      ? services.workspace.sessionPage(sessionId, sheet)
      : null;
  String? error;
  bool addToRoster = false;
  bool anySaved = false;
  final edits = [edit];
  final pages = [
    for (final s in (report['students']! as List).cast<Map<String, Object?>>())
      s['page']! as int,
  ]..sort();

  void loadSheet(int page) {
    report = services.workspace.analysisReport(sessionId);
    student = (report['students']! as List)
        .cast<Map<String, Object?>>()
        .firstWhere((s) => s['page'] == page);
    sheet = page;
    edit = ReviewSheetEdit(
      sheet: sheet,
      originalId:
          (student['student_id'] ?? student['student_id_read'] ?? '') as String,
      originalName: (student['student_name'] as String?) ?? '',
      roster: services.classBook.studentsOf(className),
      className: className,
    );
    edits.add(edit);
    originalAnswers = [
      for (final a
          in (student['answers']! as List).cast<Map<String, Object?>>())
        (a['marks'] ?? a['response'])! as String,
    ];
    answers = List.of(originalAnswers);
    picture = report['has_pages'] == true
        ? services.workspace.sessionPage(sessionId, sheet)
        : null;
    error = null;
    addToRoster = false;
  }

  bool getDirty() =>
      edit.changedId != null ||
      edit.changedName != null ||
      addToRoster ||
      List.generate(
        answers.length,
        (i) => answers[i] != originalAnswers[i],
      ).any((v) => v);

  try {
    return await showDialog<bool>(
          context: context,
          builder: (context) => StatefulBuilder(
            builder: (context, setState) {
              bool save() {
                final submission = collectReview(
                  sheets: [edit],
                  checked: {},
                  fixes: [],
                  answers: {},
                );
                if (submission.problem != null) {
                  setState(() => error = submission.problem);
                  return false;
                }
                final changedQuestions = {
                  for (var i = 0; i < answers.length; i++)
                    if (answers[i] != originalAnswers[i]) i + 1,
                };
                if (reviewAnswers && changedQuestions.isNotEmpty) {
                  if (submission.corrections.isEmpty) {
                    submission.corrections.add({'number': sheet});
                  }
                  submission.corrections.first['responses'] = answers;
                  submission.dismiss.addAll([
                    for (final row in reviewProblems(report))
                      if (row.sheet == sheet &&
                          changedQuestions.contains(row.question))
                        row.key,
                  ]);
                }
                final shouldAdd =
                    addToRoster &&
                    !services.classBook
                        .studentsOf(className)
                        .any((s) => sameStudentId(s.id, edit.id.trim()));
                if (shouldAdd) {
                  final problem = services.classBook.newStudentProblem(
                    className,
                    edit.id,
                    edit.name,
                  );
                  if (problem != null) {
                    setState(() => error = problem);
                    return false;
                  }
                }
                try {
                  if (!submission.isEmpty) {
                    services.workspace.correct(
                      sessionId,
                      submission.corrections,
                      dismiss: submission.dismiss,
                    );
                  }
                  if (shouldAdd) {
                    services.classBook.addStudent(
                      className,
                      id: edit.id,
                      name: edit.name,
                    );
                  }
                  anySaved = anySaved || !submission.isEmpty || shouldAdd;
                  return true;
                } on DataLinkError catch (e) {
                  setState(() => error = e.message);
                  return false;
                } on StoreError catch (e) {
                  setState(() => error = e.message);
                  return false;
                }
              }

              Future<void> move(int offset) async {
                if (getDirty()) {
                  final decision = await showDialog<String>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Unsaved changes'),
                      content: const Text(
                        'Save your changes to this sheet before moving to another scan?',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, 'cancel'),
                          child: const Text('Stay here'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(context, 'discard'),
                          child: const Text('Discard changes'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(context, 'save'),
                          child: const Text('Save and continue'),
                        ),
                      ],
                    ),
                  );
                  if (!context.mounted ||
                      decision == null ||
                      decision == 'cancel') {
                    return;
                  }
                  if (decision == 'save' && !save()) return;
                }
                setState(() => loadSheet(pages[pages.indexOf(sheet) + offset]));
              }

              final correctionFields = Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ListenableBuilder(
                    listenable: edit,
                    builder: (context, _) => StudentIdentityFields(
                      sheet: sheet,
                      edit: edit,
                      alwaysShowName: true,
                      onView: report['has_pages'] == true
                          ? (page) => showPagePicture(
                              context,
                              title: 'Sheet $page',
                              page: page,
                              pages: pages,
                              loadPage: (number) => services.workspace
                                  .sessionPage(sessionId, number),
                              note: 'Read the name and ID from the scan, then edit the student details.',
                              picture: services.workspace.sessionPage(
                                sessionId,
                                page,
                              ),
                            )
                          : null,
                    ),
                  ),
                  if (services.classBook.byName(className) != null)
                    ListenableBuilder(
                      listenable: edit,
                      builder: (context, _) {
                        final alreadyListed = services.classBook
                            .studentsOf(className)
                            .any((s) => sameStudentId(s.id, edit.id.trim()));
                        return CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            alreadyListed
                                ? 'Already on the $className roster'
                                : 'Add to $className roster',
                          ),
                          subtitle: alreadyListed
                              ? null
                              : const Text(
                                  'Save this name and ID for future scans too.',
                                ),
                          value: addToRoster && !alreadyListed,
                          onChanged: alreadyListed
                              ? null
                              : (value) => setState(
                                  () => addToRoster = value ?? false,
                                ),
                          controlAffinity: ListTileControlAffinity.leading,
                        );
                      },
                    ),
                  if (reviewAnswers) ...[
                    const SizedBox(height: 16),
                    const Text(
                      'Recorded answers · changes are saved only when you press Save changes.',
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        for (var i = 0; i < answers.length; i++)
                          SizedBox(
                            width: 170,
                            child: DropdownButtonFormField<String>(
                              key: ValueKey('answer-$sheet-$i-${answers[i]}'),
                              initialValue: answers[i],
                              isExpanded: true,
                              decoration: InputDecoration(
                                labelText: 'Question ${i + 1}',
                              ),
                              items: [
                                for (final value in {
                                  // Matching on the printable sheets runs
                                  // past E; the report says which letters.
                                  ...(_letters(student, i)).split(''),
                                  'BLANK',
                                  'MULTIPLE',
                                  originalAnswers[i],
                                })
                                  DropdownMenuItem(
                                    value: value,
                                    child: Text(
                                      value == 'BLANK'
                                          ? 'Blank'
                                          : value == 'MULTIPLE'
                                          ? 'Multiple'
                                          : value,
                                    ),
                                  ),
                              ],
                              onChanged: (value) => setState(
                                () => answers[i] = value ?? answers[i],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                  if (error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              );
              final scanPreview = picture == null
                  ? const Center(
                      child: Text(
                        'No scan image is available for this sheet. You can still check and correct its recorded answers.',
                      ),
                    )
                  : SizedBox.expand(
                      child: InteractiveViewer(
                        key: ValueKey('scan-$sheet'),
                        maxScale: 6,
                        child: Image.memory(
                          picture!,
                          fit: BoxFit.contain,
                          width: double.infinity,
                          height: double.infinity,
                        ),
                      ),
                    );
              return AlertDialog(
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${reviewAnswers ? 'Review scan' : 'Edit student'} · Sheet $sheet',
                    ),
                    if (reviewAnswers)
                      Row(
                        children: [
                          TextButton.icon(
                            onPressed: pages.indexOf(sheet) == 0
                                ? null
                                : () => move(-1),
                            icon: const Icon(Icons.chevron_left),
                            label: const Text('Previous'),
                          ),
                          Text(
                            '${pages.indexOf(sheet) + 1} of ${pages.length}',
                          ),
                          TextButton.icon(
                            onPressed: pages.indexOf(sheet) == pages.length - 1
                                ? null
                                : () => move(1),
                            icon: const Icon(Icons.chevron_right),
                            label: const Text('Next'),
                          ),
                        ],
                      ),
                  ],
                ),
                content: SizedBox(
                  width: reviewAnswers ? 1400 : 600,
                  height: reviewAnswers
                      ? (MediaQuery.sizeOf(context).height - 240).clamp(
                          280.0,
                          800.0,
                        )
                      : null,
                  child: reviewAnswers
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              flex: 5,
                              child: SizedBox(
                                key: const ValueKey('scan-pane'),
                                child: scanPreview,
                              ),
                            ),
                            const VerticalDivider(width: 32),
                            Expanded(
                              flex: 4,
                              child: SingleChildScrollView(
                                key: ValueKey('corrections-$sheet'),
                                child: SizedBox(
                                  key: const ValueKey('correction-pane'),
                                  child: correctionFields,
                                ),
                              ),
                            ),
                          ],
                        )
                      : SingleChildScrollView(
                          key: ValueKey(sheet),
                          child: correctionFields,
                        ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, anySaved),
                    child: Text(reviewAnswers && anySaved ? 'Close' : 'Cancel'),
                  ),
                  FilledButton(
                    onPressed: () {
                      if (save()) {
                        if (reviewAnswers) {
                          setState(() => loadSheet(sheet));
                        } else {
                          Navigator.pop(context, anySaved);
                        }
                      }
                    },
                    child: const Text('Save changes'),
                  ),
                ],
              );
            },
          ),
        ) ??
        anySaved;
  } finally {
    // The dialog's reverse transition can still be listening to the model.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final item in edits) {
        item.dispose();
      }
    });
  }
}

/// The answer letters question [index] offers on [student]'s sheet.
String _letters(Map<String, Object?> student, int index) {
  final answers = (student['answers'] as List?) ?? const [];
  if (index >= answers.length) return 'ABCDE';
  return ((answers[index] as Map)['options'] as String?) ?? 'ABCDE';
}

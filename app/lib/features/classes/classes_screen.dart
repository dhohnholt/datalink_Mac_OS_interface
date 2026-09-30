import 'package:datalink_core/datalink_core.dart';
import 'package:flutter/material.dart';

import '../../app/scope.dart';
import '../../ui/widgets.dart';
import 'class_book.dart';

/// Saved classes: the list, and an editor for one at a time.
class ClassesScreen extends StatefulWidget {
  const ClassesScreen({super.key});

  @override
  State<ClassesScreen> createState() => _ClassesScreenState();
}

class _ClassesScreenState extends State<ClassesScreen> {
  /// Null when the editor is closed; '' when adding a new class.
  String? _editing;
  final _name = TextEditingController();
  final _roster = TextEditingController();
  final _nameFocus = FocusNode();

  ClassBook? _book;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final book = Services.of(context).classBook;
    if (_book == book) return;
    _book?.editorRequest.removeListener(_fromMenu);
    _book = book..editorRequest.addListener(_fromMenu);
    // A request made before this screen existed (File > New Class… from another
    // tab) is waiting for it.
    if (book.editorRequest.value != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _fromMenu() : null);
    }
  }

  void _fromMenu() {
    final request = _book?.editorRequest.value;
    if (request == null) return;
    _book!.editorRequest.value = null;
    _open(request.name);
  }

  @override
  void dispose() {
    _book?.editorRequest.removeListener(_fromMenu);
    _name.dispose();
    _roster.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  void _open(String? existing) {
    final book = Services.of(context).classBook;
    setState(() {
      _editing = existing ?? '';
      _name.text = existing ?? '';
      _roster.text = existing == null ? '' : book.rosterText(existing);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _nameFocus.requestFocus());
  }

  void _close() => setState(() => _editing = null);

  void _save() {
    final book = Services.of(context).classBook;
    final original = _editing!.isEmpty ? null : _editing;
    try {
      final count = book.save(
        name: _name.text,
        rosterText: _roster.text,
        originalName: original,
      );
      showToast(context, 'Saved ${_name.text.trim()} with $count students');
      _close();
    } on DataLinkError catch (error) {
      showToast(context, error.message);
    } on StoreError catch (error) {
      showToast(context, error.message);
    }
  }

  Future<void> _delete() async {
    final name = _editing!;
    final book = Services.of(context).classBook;
    final ok = await confirmDialog(
      context,
      title: 'Delete class',
      message: 'Delete the saved class “$name”? Saved sessions are not affected.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok || !mounted) return;
    book.delete(name);
    _close();
  }

  @override
  Widget build(BuildContext context) {
    final book = Services.of(context).classBook;
    return ListenableBuilder(
      listenable: book,
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            SectionCard(
              title: 'Classes',
              subtitle: 'Rosters let the app name each student from the ID bubbled on the sheet.',
              trailing: FilledButton.icon(
                onPressed: () => _open(null),
                icon: const Icon(Icons.add),
                label: const Text('New class'),
              ),
              child: book.classes.isEmpty
                  ? const EmptyState(
                      title: 'No classes yet',
                      message: 'Add a class to name students automatically while you scan.',
                      icon: Icons.groups_outlined,
                    )
                  : Column(
                      children: [
                        for (final entry in book.classes)
                          _ClassRow(
                            name: entry['name']! as String,
                            students: (entry['students']! as List).length,
                            inUse: entry['name'] == book.selectedName,
                            onUse: () {
                              book.select(entry['name']! as String);
                              showToast(context, 'Scanning against ${entry['name']}');
                            },
                            onEdit: () => _open(entry['name']! as String),
                          ),
                      ],
                    ),
            ),
            if (_editing != null)
              SectionCard(
                title: _editing!.isEmpty ? 'Add a class' : 'Edit class',
                subtitle: 'One student per line: the ID, a comma, then the name.',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: _name,
                      focusNode: _nameFocus,
                      decoration: const InputDecoration(labelText: 'Class name'),
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _roster,
                      minLines: 8,
                      maxLines: 16,
                      decoration: const InputDecoration(
                        labelText: 'Roster',
                        hintText: '900011, Ada Lovelace\n900012, Grace Hopper',
                        alignLabelWithHint: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        if (_editing!.isNotEmpty)
                          TextButton.icon(
                            onPressed: _delete,
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('Delete class'),
                            style: TextButton.styleFrom(
                              foregroundColor: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        const Spacer(),
                        OutlinedButton(onPressed: _close, child: const Text('Cancel')),
                        const SizedBox(width: 8),
                        FilledButton(onPressed: _save, child: const Text('Save class')),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ClassRow extends StatelessWidget {
  const _ClassRow({
    required this.name,
    required this.students,
    required this.inUse,
    required this.onUse,
    required this.onEdit,
  });

  final String name;
  final int students;
  final bool inUse;
  final VoidCallback onUse;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '$name, $students ${students == 1 ? 'student' : 'students'}'
          '${inUse ? ', in use for scanning' : ''}',
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text('$students ${students == 1 ? 'student' : 'students'}'),
        leading: inUse
            ? const Tooltip(message: 'In use for scanning', child: Icon(Icons.check_circle, color: Color(0xFF2E9E57)))
            : const SizedBox(width: 24),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!inUse) TextButton(onPressed: onUse, child: const Text('Use for scanning')),
            const SizedBox(width: 4),
            OutlinedButton(onPressed: onEdit, child: const Text('Edit')),
          ],
        ),
      ),
    );
  }
}

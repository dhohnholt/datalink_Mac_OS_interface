import 'package:datalink_core/datalink_core.dart';
import 'package:flutter/foundation.dart';

/// A request, from the menu, to open the class editor: for [name], or a new
/// class when null. `serial` makes two identical requests distinct.
typedef EditorRequest = ({String? name, int serial});

/// The saved classes and which one scanning is using. In the old page these
/// were globals in app.js (`classes`, `selectedClassName`) read by the Scan,
/// Paper, Classes and Analysis tabs; here they are one object they all watch.
class ClassBook extends ChangeNotifier {
  ClassBook(this._store) {
    load();
  }

  final Store _store;

  /// Listened to by the Classes screen.
  final ValueNotifier<EditorRequest?> editorRequest = ValueNotifier(null);
  int _requests = 0;

  void requestEditor(String? name) => editorRequest.value = (name: name, serial: ++_requests);

  List<Map<String, Object?>> _classes = const [];
  String _selected = '';

  List<Map<String, Object?>> get classes => _classes;

  /// The class scanning is against, or '' for "No roster".
  String get selectedName => _selected;

  void load() {
    _classes = _store.listClasses();
    final saved = _store.getSetting('selected_class');
    _selected = _classes.any((c) => c['name'] == saved) ? saved : '';
    notifyListeners();
  }

  Map<String, Object?>? byName(String name) {
    for (final entry in _classes) {
      if (entry['name'] == name) return entry;
    }
    return null;
  }

  /// The students of a class, in roster order. Empty for an unknown name.
  List<RosterStudent> studentsOf(String name) => [
        for (final s in (byName(name)?['students'] as List<Object?>? ?? const []).cast<Map<String, Object?>>())
          (id: s['id']! as String, name: s['name']! as String),
      ];

  /// `id, name` lines for the editor.
  String rosterText(String name) =>
      studentsOf(name).map((s) => '${s.id}, ${s.name}').join('\n');

  /// Use [name] for scanning ('' turns the roster off).
  void select(String name) {
    _store.setSetting('selected_class', name);
    _selected = name;
    notifyListeners();
  }

  /// Save a class from the editor. Returns the number of students saved.
  /// Throws a [DataLinkError] or [StoreError] with words fit for the teacher.
  int save({required String name, required String rosterText, String? originalName}) {
    final students = parseRoster(rosterText);
    final trimmed = name.trim();
    _store.saveClass(
      trimmed,
      [for (final s in students) {'id': s.id, 'name': s.name}],
      originalName,
    );
    // Renaming the class that scanning is using keeps it in use; saving the
    // first class ever selects it.
    if (_selected == (originalName ?? '') && originalName != null) _selected = trimmed;
    if (_selected.isEmpty) _selected = trimmed;
    _store.setSetting('selected_class', _selected);
    _classes = _store.listClasses();
    notifyListeners();
    return students.length;
  }

  void delete(String name) {
    _store.deleteClass(name);
    if (_selected == name) {
      _selected = '';
      _store.setSetting('selected_class', '');
    }
    _classes = _store.listClasses();
    notifyListeners();
  }
}

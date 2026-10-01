import 'package:datalink_core/datalink_core.dart';
import 'package:flutter/material.dart';

/// Light, dark, or whatever the Mac is set to. Remembered between launches.
class Appearance extends ChangeNotifier {
  Appearance(this._store) : _mode = _read(_store);

  static const String setting = 'appearance';

  final Store _store;
  ThemeMode _mode;

  ThemeMode get mode => _mode;

  void set(ThemeMode mode) {
    if (mode == _mode) return;
    _mode = mode;
    _store.setSetting(setting, mode.name);
    notifyListeners();
  }

  static ThemeMode _read(Store store) => switch (store.getSetting(setting)) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  static String label(ThemeMode mode) => switch (mode) {
        ThemeMode.system => 'Match System',
        ThemeMode.light => 'Light',
        ThemeMode.dark => 'Dark',
      };
}

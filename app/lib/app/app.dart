import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import '../ui/shell.dart';
import 'palette.dart';
import 'navigation.dart';
import 'scope.dart';
import 'services.dart';

/// The whole app once its services exist.
class DataLinkApp extends StatefulWidget {
  const DataLinkApp({super.key, required this.services, this.screens = const {}});

  final AppServices services;

  /// Replaces screens by tab; tests use it to keep hardware out of the picture.
  final Map<AppView, ScreenBuilder> screens;

  @override
  State<DataLinkApp> createState() => _DataLinkAppState();
}

class _DataLinkAppState extends State<DataLinkApp> {
  final AppNavigation _navigation = AppNavigation();

  /// On Quit, end any running session, release the serial port and fold the
  /// database's write-ahead log back in, before the process goes.
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        await widget.services.dispose();
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _navigation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Services(
      services: widget.services,
      child: Nav(
        navigation: _navigation,
        child: MaterialApp(
          title: 'DataLink Scanner',
          debugShowCheckedModeBanner: false,
          theme: Palette.light.theme(),
          darkTheme: Palette.dark.theme(),
          home: AppShell(screens: widget.screens),
        ),
      ),
    );
  }
}

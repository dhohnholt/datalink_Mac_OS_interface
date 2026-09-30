import 'dart:io';

import 'package:datalink_core/datalink_core.dart';
import 'package:datalink_serial_posix/datalink_serial_posix.dart';
import 'package:flutter/material.dart';

import 'app/app.dart';
import 'app/keychain_store.dart';
import 'app/services.dart';
import 'hardware_check/hardware_check.dart';

const String appVersion = '2.0.0+1';

Future<void> main() async {
  // Headless mode for checking the sandboxed build from a terminal, where the
  // report lands on stdout instead of a window:
  //   DATALINK_HARDWARE_CHECK=1 "DataLink Scanner.app/Contents/MacOS/DataLink Scanner"
  final env = Platform.environment;
  if (env['DATALINK_HARDWARE_CHECK'] == '1') {
    final listen = int.tryParse(env['DATALINK_HARDWARE_LISTEN'] ?? '') ?? 0;
    final check = HardwareCheck(
      transport: PosixSerialTransport(),
      clock: SystemClock(),
      deviceDirectory: '/dev',
      appVersion: appVersion,
    );
    stdout.writeln(await check.run(listenFor: Duration(seconds: listen)));
    exit(0);
  }

  // Headless check that the signed build may open an outgoing connection:
  //   DATALINK_NETWORK_SELFTEST=127.0.0.1:8765 "DataLink Scanner.app/Contents/MacOS/DataLink Scanner"
  final probe = env['DATALINK_NETWORK_SELFTEST'];
  if (probe != null) {
    final parts = probe.split(':');
    try {
      final socket = await Socket.connect(parts[0], int.parse(parts[1]), timeout: const Duration(seconds: 3));
      stdout.writeln('connect $probe: ok');
      socket.destroy();
    } on Object catch (error) {
      stdout.writeln('connect $probe: FAILED $error');
    }
    exit(0);
  }

  WidgetsFlutterBinding.ensureInitialized();
  // Headless check of the Keychain from a signed, sandboxed build:
  //   DATALINK_KEYCHAIN_SELFTEST=1 "DataLink Scanner.app/Contents/MacOS/DataLink Scanner"
  if (env['DATALINK_KEYCHAIN_SELFTEST'] == '1') {
    stdout.writeln(await keychainSelfTest(const KeychainSecretStore()));
    exit(0);
  }
  final services = await AppServices.start();
  runApp(DataLinkApp(services: services));
}

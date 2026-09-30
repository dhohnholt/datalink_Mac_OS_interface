import 'package:datalink_core/datalink_core.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The macOS Keychain behind [SecretStore].
///
/// The **legacy** (file-based) keychain is used on purpose: the data-protection
/// keychain the plugin defaults to needs a `keychain-access-groups`
/// entitlement, which is one more thing to ask the App Store for, and this app
/// stores one small token. The service is the Keychain item's service
/// attribute and the account its account, exactly as in the Python app.
class KeychainSecretStore implements SecretStore {
  const KeychainSecretStore();

  FlutterSecureStorage _storage(String service) => FlutterSecureStorage(
        mOptions: MacOsOptions(accountName: service, usesDataProtectionKeychain: false),
      );

  @override
  Future<String?> read(String service, String account) => _storage(service).read(key: account);

  @override
  Future<void> write(String service, String account, String secret) =>
      _storage(service).write(key: account, value: secret);

  @override
  Future<bool> delete(String service, String account) async {
    final storage = _storage(service);
    final existed = await storage.containsKey(key: account);
    await storage.delete(key: account);
    return existed;
  }
}

/// Exercise the Keychain end to end with a throwaway item, and report what
/// happened. Used to check a signed, sandboxed build from a terminal.
Future<String> keychainSelfTest(SecretStore store) async {
  const service = 'org.davidhohnholt.datalink-scanner.selftest';
  const account = 'selftest';
  final lines = <String>[];
  try {
    await store.write(service, account, 'first');
    lines.add('write: ok');
    lines.add('read: ${await store.read(service, account)}');
    await store.write(service, account, 'second');
    lines.add('overwrite then read: ${await store.read(service, account)}');
    lines.add('delete removed something: ${await store.delete(service, account)}');
    lines.add('read after delete: ${await store.read(service, account)}');
    lines.add('delete again removed something: ${await store.delete(service, account)}');
  } on Object catch (error) {
    lines.add('FAILED: $error');
    try {
      await store.delete(service, account);
    } on Object {
      // Nothing more to do.
    }
  }
  return lines.join('\n');
}

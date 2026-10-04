import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:mylittlenotebooks/data/secrets/token_store.dart';

/// The production [TokenStore], over `flutter_secure_storage`.
///
/// This is the **only** file in `lib/` permitted to import
/// `package:flutter_secure_storage`; the purity test enforces that (FR4, NFR2).
///
/// The macOS options disable the data-protection keychain deliberately. This app
/// already carries an App Group for ObjectBox, and the plugin documents that the
/// data-protection keychain then requires the App Group in
/// `keychain-access-groups` — an entitlement with signing consequences — or
/// writes *appear to succeed and never land*. The legacy keychain avoids that
/// requirement for an app that does not share keychain items with another app.
/// The choice is recorded, and the only proof it works is a real macOS run
/// (see `test/secure_config_purity_test.dart`'s manual-gate group).
class FlutterSecureTokenStore implements TokenStore {
  FlutterSecureTokenStore({FlutterSecureStorage? storage})
      : _storage = storage ?? _defaultStorage();

  final FlutterSecureStorage _storage;

  static FlutterSecureStorage _defaultStorage() => const FlutterSecureStorage(
        mOptions: MacOsOptions(usesDataProtectionKeychain: false),
      );

  @override
  Future<void> write(String uuid, String token) => _guard(
        () => _storage.write(key: aiConfigTokenKey(uuid), value: token),
      );

  @override
  Future<void> delete(String uuid) =>
      _guard(() => _storage.delete(key: aiConfigTokenKey(uuid)));

  @override
  Future<bool> exists(String uuid) =>
      _guard(() => _storage.containsKey(key: aiConfigTokenKey(uuid)));

  @override
  Future<String?> read(String uuid) =>
      _guard(() => _storage.read(key: aiConfigTokenKey(uuid)));

  @override
  Future<Map<String, String>> readAll() => _guard(() async {
        final all = await _storage.readAll();
        return {
          for (final entry in all.entries)
            if (entry.key.startsWith(aiConfigTokenKeyPrefix))
              entry.key: entry.value,
        };
      });

  /// Translates platform failures into [TokenStoreUnavailableException] so the
  /// save path can fail loudly instead of writing a token somewhere readable
  /// (FR17, AC14). It never swallows an error.
  Future<T> _guard<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on TokenStoreUnavailableException {
      rethrow;
    } on PlatformException catch (error) {
      // 11.x surfaces a locked/unavailable Linux keyring as a catchable
      // PlatformException (codes `KeyringLocked`, `StorageError`).
      throw TokenStoreUnavailableException(
        '${error.code}: ${error.message ?? 'secret store unavailable'}',
      );
    } on MissingPluginException catch (error) {
      throw TokenStoreUnavailableException('secret store plugin missing: $error');
    }
  }
}

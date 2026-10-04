import 'package:flutter/services.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:mylittlenotebooks/data/secrets/token_store.dart';

/// An in-memory [TokenStore] for tests.
///
/// The whole suite exercises the secret seam through this rather than a real
/// keychain (spec NFR3, AC23). It counts calls so the "listing must not read a
/// token" requirement (AC16) is assertable, and it can be made to fail so the
/// no-plaintext-fallback path (FR17, AC14) is assertable.
class FakeTokenStore implements TokenStore {
  final Map<String, String> _values = <String, String>{};

  /// When true, [write] throws as a locked/unavailable keyring would.
  bool failWrites = false;

  /// When true, [readAll] throws as the macOS legacy keychain does (it rejects
  /// `kSecMatchLimitAll` with `errSecParam`/-50).
  bool failReadAll = false;

  int readCalls = 0;
  int writeCalls = 0;
  int deleteCalls = 0;
  int existsCalls = 0;

  /// Puts a token in the store without going through [write] (call counter
  /// untouched), for seeding a scenario.
  void seed(String uuid, String token) {
    _values[aiConfigTokenKey(uuid)] = token;
  }

  bool has(String uuid) => _values.containsKey(aiConfigTokenKey(uuid));

  String? valueOf(String uuid) => _values[aiConfigTokenKey(uuid)];

  @override
  Future<void> write(String uuid, String token) async {
    writeCalls++;
    if (failWrites) {
      throw const TokenStoreUnavailableException('fake: keyring unavailable');
    }
    _values[aiConfigTokenKey(uuid)] = token;
  }

  @override
  Future<void> delete(String uuid) async {
    deleteCalls++;
    _values.remove(aiConfigTokenKey(uuid));
  }

  @override
  Future<bool> exists(String uuid) async {
    existsCalls++;
    return _values.containsKey(aiConfigTokenKey(uuid));
  }

  @override
  Future<String?> read(String uuid) async {
    readCalls++;
    return _values[aiConfigTokenKey(uuid)];
  }

  @override
  Future<Map<String, String>> readAll() async {
    if (failReadAll) {
      throw const TokenStoreUnavailableException(
        'fake: enumeration unsupported (kSecMatchLimitAll)',
      );
    }
    return Map<String, String>.of(_values);
  }
}

/// A platform implementation that always throws, used to prove
/// [FlutterSecureTokenStore] converts platform failures into
/// [TokenStoreUnavailableException] rather than swallowing them (FR17).
class ThrowingSecureStoragePlatform extends FlutterSecureStoragePlatform {
  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async => throw _failure;

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async => throw _failure;

  @override
  Future<void> deleteAll({required Map<String, String> options}) async =>
      throw _failure;

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async => throw _failure;

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async => throw _failure;

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async => throw _failure;
}

final _failure = PlatformException(
  code: 'KeyringLocked',
  message: 'fake: keyring is locked',
);

import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/data/secrets/flutter_secure_token_store.dart';
import 'package:mylittlenotebooks/data/secrets/token_store.dart';

import 'test_token_store.dart';

/// The secret seam's own tests (settings-for-ai FR3, FR4, FR17; AC23).
///
/// No test here touches a real keychain: the fake is used for the interface
/// contract, and the plugin's own in-memory platform is used to exercise the
/// production wrapper's key derivation and failure translation.
void main() {
  group('key derivation', () {
    test('a tuple token is stored under a uuid-derived key', () {
      expect(aiConfigTokenKey('abc'), '${aiConfigTokenKeyPrefix}abc');
      expect(aiConfigTokenKey('abc').startsWith(aiConfigTokenKeyPrefix), isTrue);
    });
  });

  group('FakeTokenStore contract', () {
    test('write / exists / read / delete round-trip', () async {
      final store = FakeTokenStore();
      expect(await store.exists('u1'), isFalse);
      expect(await store.read('u1'), isNull);

      await store.write('u1', 'secret-1');
      expect(await store.exists('u1'), isTrue);
      expect(await store.read('u1'), 'secret-1');

      await store.delete('u1');
      expect(await store.exists('u1'), isFalse);
      expect(await store.read('u1'), isNull);
    });

    test('readMany returns only the uuids that have tokens', () async {
      final store = FakeTokenStore()..seed('a', 'ta');
      final found = await store.readMany(['a', 'b', 'c']);
      expect(found, {'a': 'ta'});
    });

    test('an injected write failure surfaces as TokenStoreUnavailableException',
        () async {
      final store = FakeTokenStore()..failWrites = true;
      await expectLater(
        store.write('u1', 'secret'),
        throwsA(isA<TokenStoreUnavailableException>()),
      );
      expect(store.has('u1'), isFalse);
    });
  });

  group('FlutterSecureTokenStore', () {
    late Map<String, String> backing;

    setUp(() {
      backing = <String, String>{};
      FlutterSecureStoragePlatform.instance =
          TestFlutterSecureStoragePlatform(backing);
    });

    test('writes and reads through the uuid-derived key', () async {
      final store = FlutterSecureTokenStore();
      await store.write('u1', 'secret-1');

      expect(backing.containsKey(aiConfigTokenKey('u1')), isTrue);
      expect(await store.exists('u1'), isTrue);
      expect(await store.read('u1'), 'secret-1');

      await store.delete('u1');
      expect(await store.exists('u1'), isFalse);
    });

    test('readAll returns only this app\'s token keys', () async {
      backing['unrelated'] = 'leave-me';
      backing[aiConfigTokenKey('u2')] = 'secret-2';

      final store = FlutterSecureTokenStore();
      final all = await store.readAll();

      expect(all, {aiConfigTokenKey('u2'): 'secret-2'});
    });

    test('a platform failure becomes a typed, catchable exception', () async {
      FlutterSecureStoragePlatform.instance = ThrowingSecureStoragePlatform();
      final store = FlutterSecureTokenStore();

      await expectLater(
        store.write('u1', 'secret'),
        throwsA(isA<TokenStoreUnavailableException>()),
      );
      await expectLater(
        store.read('u1'),
        throwsA(isA<TokenStoreUnavailableException>()),
      );
    });
  });
}

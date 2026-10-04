import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_ai_config.dart';
import 'package:mylittlenotebooks/data/objectbox/objectbox_store.dart';
import 'package:mylittlenotebooks/data/objectbox_ai_config_repository.dart';
import 'package:mylittlenotebooks/data/secrets/token_store.dart';
import 'package:mylittlenotebooks/data/sync/sync_tombstones.dart';
import 'package:mylittlenotebooks/objectbox.g.dart';

import 'test_token_store.dart';

/// The configuration CRUD and secret-storage contract (settings-for-ai
/// AC3–AC7, AC14–AC16). In-memory store + fake secret store only.
void main() {
  late Store store;
  late FakeTokenStore tokens;
  late ObjectBoxAiConfigRepository repo;

  setUp(() {
    store = openTestStore('ai-config');
    tokens = FakeTokenStore();
    repo = ObjectBoxAiConfigRepository(store, tokens);
  });

  tearDown(() => store.close());

  const sentinel = 'sk-sentinel-TOKEN-should-never-be-stored';

  group('entity shape', () {
    test('AC1: a duplicate uuid is refused by @Unique', () {
      final box = store.box<ObAiConfig>();
      box.put(ObAiConfig(
        uuid: 'dup-uuid',
        label: 'a',
        endpoint: 'http://a',
        shared: false,
        createdAt: DateTime.now().toUtc(),
      ));
      expect(
        () => box.put(ObAiConfig(
          uuid: 'dup-uuid',
          label: 'b',
          endpoint: 'http://b',
          shared: false,
          createdAt: DateTime.now().toUtc(),
        )),
        throwsA(isA<UniqueViolationException>()),
      );
    });
  });

  group('create / list / edit / delete', () {
    test('AC5: add, edit and delete round-trip', () async {
      final created = await repo.create(
        label: 'Local Ollama',
        endpoint: 'http://localhost:11434/v1',
        shared: false,
        token: 'ollama-key',
      );
      expect(created.label, 'Local Ollama');
      expect(created.hasToken, isTrue);

      expect(repo.list(), hasLength(1));
      expect(repo.list().single.uuid, created.uuid);

      await repo.update(
        created.uuid,
        label: 'Renamed',
        endpoint: 'http://localhost:11434/v2',
        shared: true,
      );
      final after = repo.list().single;
      expect(after.label, 'Renamed');
      expect(after.endpoint, 'http://localhost:11434/v2');
      expect(after.shared, isTrue);

      await repo.delete(created.uuid);
      expect(repo.list(), isEmpty);
      expect(tokens.has(created.uuid), isFalse);
    });

    test('AC3: the token never appears in any ObjectBox property', () async {
      await repo.create(
        label: 'OpenAI',
        endpoint: 'https://api.openai.com/v1',
        shared: true,
        token: sentinel,
      );

      for (final row in store.box<ObAiConfig>().getAll()) {
        expect(row.uuid.contains(sentinel), isFalse);
        expect(row.label.contains(sentinel), isFalse);
        expect(row.endpoint.contains(sentinel), isFalse);
      }
      // And it really is in the secret store.
      expect(tokens.valueOf(repo.list().single.uuid), sentinel);
    });

    test('AC4: hasToken is derived from the store, not a column', () async {
      final withToken = await repo.create(
        label: 'with',
        endpoint: 'http://a',
        shared: false,
        token: 't',
      );
      final without = await repo.create(
        label: 'without',
        endpoint: 'http://b',
        shared: false,
      );
      expect(withToken.hasToken, isTrue);
      expect(without.hasToken, isFalse);
      expect(repo.list().firstWhere((c) => c.uuid == withToken.uuid).hasToken,
          isTrue);
      expect(repo.list().firstWhere((c) => c.uuid == without.uuid).hasToken,
          isFalse);
    });

    test('AC6: editing without touching the token performs no secret operation',
        () async {
      final created = await repo.create(
        label: 'keep',
        endpoint: 'http://a',
        shared: false,
        token: 'original',
      );
      final writesBefore = tokens.writeCalls;
      final deletesBefore = tokens.deleteCalls;

      await repo.update(
        created.uuid,
        label: 'keep2',
        endpoint: 'http://a',
        shared: false,
      );

      expect(tokens.writeCalls, writesBefore);
      expect(tokens.deleteCalls, deletesBefore);
      expect(tokens.valueOf(created.uuid), 'original');
    });

    test('replacing and clearing a token works', () async {
      final created = await repo.create(
        label: 'x',
        endpoint: 'http://a',
        shared: false,
        token: 'first',
      );
      await repo.update(created.uuid,
          label: 'x', endpoint: 'http://a', shared: false, newToken: 'second');
      expect(tokens.valueOf(created.uuid), 'second');
      expect(repo.list().single.hasToken, isTrue);

      await repo.update(created.uuid,
          label: 'x', endpoint: 'http://a', shared: false, clearToken: true);
      expect(tokens.has(created.uuid), isFalse);
      expect(repo.list().single.hasToken, isFalse);
    });
  });

  group('delete', () {
    test('AC7: writes one tombstone at the next version and removes the secret',
        () async {
      final created = await repo.create(
        label: 'gone',
        endpoint: 'http://a',
        shared: true,
        token: 'secret',
      );
      await repo.delete(created.uuid);

      final tombstones = TombstoneStore(store).all();
      expect(tombstones, hasLength(1));
      // Created at version 1; the delete is the next edit → 2.
      expect(tombstones.single.versionCounter, 2);
      expect(tombstones.single.uuid, created.uuid);
      expect(tokens.has(created.uuid), isFalse);
    });
  });

  group('failure paths', () {
    test('AC14: a keychain failure leaves no row and no plaintext', () async {
      tokens.failWrites = true;
      await expectLater(
        repo.create(
          label: 'x',
          endpoint: 'http://a',
          shared: false,
          token: sentinel,
        ),
        throwsA(isA<TokenStoreUnavailableException>()),
      );

      expect(store.box<ObAiConfig>().count(), 0);
    });
  });

  group('flags and reconciliation', () {
    test('AC16: listing reads no token', () async {
      await repo.create(
        label: 'x',
        endpoint: 'http://a',
        shared: false,
        token: 't',
      );
      await repo.create(label: 'y', endpoint: 'http://b', shared: false);

      final readsBefore = tokens.readCalls;
      final existsBefore = tokens.existsCalls;
      repo.list();
      expect(tokens.readCalls, readsBefore,
          reason: 'listing must never read a secret (FR5, NFR6)');
      expect(tokens.existsCalls, existsBefore,
          reason: 'listing uses the warm flag cache, not the store');
    });

    test('AC15: reconcile removes an orphan secret', () async {
      tokens.seed('orphan-uuid', 'no-row-for-me');
      await repo.reconcile();
      expect(tokens.has('orphan-uuid'), isFalse);
    });

    test('AC15: a row whose secret vanished reports hasToken false', () async {
      final created = await repo.create(
        label: 'x',
        endpoint: 'http://a',
        shared: false,
        token: 't',
      );
      // Simulate the secret disappearing underneath a live row.
      await tokens.delete(created.uuid);
      await repo.refreshTokenFlags();

      expect(repo.list().single.hasToken, isFalse);
    });

    test('reconcile tolerates a platform that cannot enumerate', () async {
      // macOS legacy keychain rejects kSecMatchLimitAll with errSecParam(-50).
      // Orphan cleanup must not stop the app booting; flags still refresh.
      final created = await repo.create(
        label: 'x',
        endpoint: 'http://a',
        shared: false,
        token: 't',
      );
      tokens.failReadAll = true;

      await expectLater(repo.reconcile(), completes);

      expect(repo.list().single.hasToken, isTrue,
          reason: 'refreshTokenFlags still ran, so hasToken does not lie');
      expect(repo.list().single.uuid, created.uuid);
    });
  });

  group('tokenFor', () {
    test('returns the stored token to the data/sync layer only', () async {
      final created = await repo.create(
        label: 'x',
        endpoint: 'http://a',
        shared: true,
        token: 'the-secret',
      );
      expect(await repo.tokenFor(created.uuid), 'the-secret');
      expect(await repo.tokenFor('missing'), isNull);
    });
  });
}

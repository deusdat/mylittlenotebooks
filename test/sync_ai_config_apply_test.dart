import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/data/identity.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_ai_config.dart';
import 'package:mylittlenotebooks/data/objectbox/objectbox_store.dart';
import 'package:mylittlenotebooks/data/sync/sync_apply.dart';
import 'package:mylittlenotebooks/data/sync/sync_codec.dart';
import 'package:mylittlenotebooks/data/sync/sync_payload.dart';
import 'package:mylittlenotebooks/data/sync/sync_tombstones.dart';
import 'package:mylittlenotebooks/objectbox.g.dart';

import 'sync_test_fixtures.dart';
import 'test_token_store.dart';

/// Receive-path behaviour for AI configurations (settings-for-ai AC10–AC13,
/// AC22). In-memory store + fake secret store only.
void main() {
  const me = 'd-me';
  const peer = 'd-peer';

  late Store store;
  late FakeTokenStore tokens;
  late SyncApplier applier;

  setUp(() {
    store = openTestStore('ai-config-apply');
    tokens = FakeTokenStore();
    applier = SyncApplier(
      store: store,
      activeEmbeddingModelId: testModel,
      deviceId: me,
      tokens: tokens,
    );
  });

  tearDown(() => store.close());

  AiConfigDto dto({
    required String uuid,
    required bool shared,
    required int version,
    String label = 'cfg',
    String endpoint = 'http://x',
    String? token,
  }) =>
      AiConfigDto(
        uuid: uuid,
        label: label,
        endpoint: endpoint,
        shared: shared,
        token: token,
        version: VersionDto(counter: version, deviceId: peer),
      );

  Future<IngestResult> apply(List<AiConfigDto> configs) =>
      applier.ingestEncoded(encodePayload(SyncPayload(
        publications: const [],
        deletes: const [],
        aiConfigs: configs,
      )));

  ObAiConfig? row(String uuid) =>
      store.box<ObAiConfig>().query(ObAiConfig_.uuid.equals(uuid)).build().findFirst();

  group('FR16/AC10 — a shared tuple upserts', () {
    test('creates the row and writes the token', () async {
      final id = newUuidV7();
      final result = await apply([
        dto(uuid: id, shared: true, version: 1, token: 'secret-1'),
      ]);

      expect(result.configsApplied, 1);
      expect(row(id), isNotNull);
      expect(row(id)!.shared, isTrue);
      expect(tokens.valueOf(id), 'secret-1');
    });

    test('re-ingesting the same version leaves state unchanged', () async {
      final id = newUuidV7();
      await apply([dto(uuid: id, shared: true, version: 1, token: 'secret-1')]);
      final before = row(id)!;
      final snapshot = (before.label, before.endpoint, before.shared,
          before.versionCounter, tokens.valueOf(id));

      await apply([dto(uuid: id, shared: true, version: 1, token: 'secret-1')]);

      final after = row(id)!;
      expect(
        (after.label, after.endpoint, after.shared, after.versionCounter,
            tokens.valueOf(id)),
        snapshot,
        reason: 'idempotency is measured by unchanged state, not by an '
            'operation counter: the receiver stores counters and reconstructs '
            'the deviceId half, so an equal counter can still be re-applied '
            'with identical values (docs/sync-conventions.md)',
      );
    });

    test('a higher version replaces label, endpoint and token', () async {
      final id = newUuidV7();
      await apply([
        dto(uuid: id, shared: true, version: 1, label: 'old', token: 'old-tok'),
      ]);
      await apply([
        dto(
          uuid: id,
          shared: true,
          version: 2,
          label: 'new',
          endpoint: 'http://y',
          token: 'new-tok',
        ),
      ]);

      expect(row(id)!.label, 'new');
      expect(row(id)!.endpoint, 'http://y');
      expect(tokens.valueOf(id), 'new-tok');
    });
  });

  group('FR13/AC11 — unshare removes, and does not resurrect', () {
    test('an unshared record removes the row and the token', () async {
      final id = newUuidV7();
      await apply([dto(uuid: id, shared: true, version: 1, token: 'secret')]);

      final result = await apply([dto(uuid: id, shared: false, version: 2)]);

      expect(result.configsRemoved, 1);
      expect(row(id), isNull);
      expect(tokens.has(id), isFalse);
    });

    test('an unshared record for a tuple we never had is a no-op', () async {
      final id = newUuidV7();
      final result = await apply([dto(uuid: id, shared: false, version: 1)]);

      expect(result.configsRemoved, 0);
      expect(row(id), isNull);
    });

    test('re-sharing at a higher version re-creates row and token', () async {
      final id = newUuidV7();
      await apply([dto(uuid: id, shared: true, version: 1, token: 'one')]);
      await apply([dto(uuid: id, shared: false, version: 2)]);

      await apply([dto(uuid: id, shared: true, version: 3, token: 'three')]);

      expect(row(id), isNotNull);
      expect(tokens.valueOf(id), 'three');
    });
  });

  group('FR14/AC12/AC13 — delete and anti-resurrection', () {
    test('a delete removes the tuple, its token, and writes a tombstone',
        () async {
      final id = newUuidV7();
      await apply([dto(uuid: id, shared: true, version: 1, token: 'secret')]);

      final result = await applier.ingestEncoded(encodePayload(SyncPayload(
        publications: const [],
        deletes: [
          DeleteDto(
            uuid: id,
            version: const VersionDto(counter: 2, deviceId: peer),
          ),
        ],
      )));

      expect(result.deletesApplied, 1);
      expect(row(id), isNull);
      expect(tokens.has(id), isFalse);
      expect(TombstoneStore(store).isDead(id), isTrue);
    });

    test('a tombstoned uuid refuses a later higher-version upsert', () async {
      final id = newUuidV7();
      await applier.ingestEncoded(encodePayload(SyncPayload(
        publications: const [],
        deletes: [
          DeleteDto(
            uuid: id,
            version: const VersionDto(counter: 5, deviceId: peer),
          ),
        ],
      )));

      final result =
          await apply([dto(uuid: id, shared: true, version: 6, token: 'x')]);

      expect(result.configsApplied, 0);
      expect(row(id), isNull);
      expect(tokens.has(id), isFalse);
    });

    test('AC13: a delete for an unknown uuid is a no-op that still tombstones',
        () async {
      final id = newUuidV7();
      final result = await applier.ingestEncoded(encodePayload(SyncPayload(
        publications: const [],
        deletes: [
          DeleteDto(
            uuid: id,
            version: const VersionDto(counter: 1, deviceId: peer),
          ),
        ],
      )));

      expect(result.deletesApplied, 1);
      expect(row(id), isNull);
      expect(TombstoneStore(store).isDead(id), isTrue);
    });
  });

  group('AC22 — no secret in diagnostics', () {
    test('IngestResult.toString() does not contain a token', () async {
      const sentinel = 'sk-sentinel-TOKEN';
      final id = newUuidV7();
      final result =
          await apply([dto(uuid: id, shared: true, version: 1, token: sentinel)]);

      expect(result.toString().contains(sentinel), isFalse);
    });
  });
}

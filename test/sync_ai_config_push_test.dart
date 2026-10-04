import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/data/identity.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_ai_config.dart';
import 'package:mylittlenotebooks/data/objectbox/objectbox_store.dart';
import 'package:mylittlenotebooks/data/sync/push_sender.dart';
import 'package:mylittlenotebooks/data/sync/sync_codec.dart';
import 'package:mylittlenotebooks/data/sync/sync_payload.dart';
import 'package:mylittlenotebooks/objectbox.g.dart';

import 'test_token_store.dart';

/// Shared-tuple selection (settings-for-ai AC8, AC9, AC22).
///
/// Uuids here are real UUIDv7 values: the codec validates every identifier on
/// the way out, so a placeholder like `cfg-1` would be refused.
void main() {
  const peer = 'd-peer';

  late Store store;
  late FakeTokenStore tokens;
  late PushSender sender;

  setUp(() {
    store = openTestStore('ai-config-push');
    tokens = FakeTokenStore();
    sender = PushSender(
      store: store,
      deviceId: 'd-me',
      tokens: tokens,
    );
  });

  tearDown(() => store.close());

  void seed({
    required String uuid,
    bool shared = true,
    int version = 1,
    String label = 'cfg',
    String endpoint = 'http://x',
  }) {
    store.box<ObAiConfig>().put(ObAiConfig(
      uuid: uuid,
      label: label,
      endpoint: endpoint,
      shared: shared,
      createdAt: DateTime.now().toUtc(),
      versionCounter: version,
    ));
  }

  void setShared(String uuid, {required bool shared, required int version}) {
    final box = store.box<ObAiConfig>();
    final e = box.query(ObAiConfig_.uuid.equals(uuid)).build().findFirst()!;
    e.shared = shared;
    e.versionCounter = version;
    box.put(e);
  }

  group('FR12/AC8 — a shared tuple travels, a private one does not', () {
    test('a shared tuple with a moved version is selected', () {
      final id = newUuidV7();
      seed(uuid: id);
      final delta = sender.selectDelta(peer, tokens: {id: 'tok'});

      expect(delta.aiConfigs, hasLength(1));
      final dto = delta.aiConfigs.single;
      expect(dto.uuid, id);
      expect(dto.shared, isTrue);
      expect(dto.token, 'tok');
    });

    test('a never-shared tuple is absent from the delta', () {
      seed(uuid: newUuidV7(), shared: false);

      expect(sender.selectDelta(peer).aiConfigs, isEmpty,
          reason: 'a private tuple must never be broadcast, not even as a '
              'removal');
    });

    test('re-pushing an unchanged shared tuple sends nothing', () {
      seed(uuid: newUuidV7());
      sender.acknowledge(peer, sender.selectDelta(peer));

      expect(sender.selectDelta(peer).aiConfigs, isEmpty);
    });
  });

  group('FR13/AC8 — unshare is a removal, not a tombstone', () {
    test('a shared-then-unshared tuple is sent as shared:false with no token',
        () {
      final id = newUuidV7();
      seed(uuid: id, shared: true, version: 1);
      sender.acknowledge(peer, sender.selectDelta(peer, tokens: {id: 'tok'}));

      setShared(id, shared: false, version: 2);

      final delta = sender.selectDelta(peer);
      expect(delta.aiConfigs, hasLength(1));
      expect(delta.aiConfigs.single.shared, isFalse);
      expect(delta.aiConfigs.single.token, isNull);

      sender.acknowledge(peer, delta);
      expect(sender.selectDelta(peer).aiConfigs, isEmpty,
          reason: 'once the unshare is acknowledged it is not re-sent');
    });

    test('re-sharing after an unshare sends it again', () {
      final id = newUuidV7();
      seed(uuid: id, shared: true, version: 1);
      sender.acknowledge(peer, sender.selectDelta(peer, tokens: {id: 'tok'}));
      setShared(id, shared: false, version: 2);
      sender.acknowledge(peer, sender.selectDelta(peer));

      setShared(id, shared: true, version: 3);

      final delta = sender.selectDelta(peer, tokens: {id: 'tok2'});
      expect(delta.aiConfigs, hasLength(1));
      expect(delta.aiConfigs.single.shared, isTrue);
      expect(delta.aiConfigs.single.token, 'tok2');
    });
  });

  group('FR11/AC8 — push preloads tokens for shared tuples only', () {
    test('push delivers the token and acknowledges a shared tuple', () async {
      final id = newUuidV7();
      seed(uuid: id, shared: true);
      tokens.seed(id, 'the-secret');

      String? captured;
      await sender.push(peer, (encoded) async => captured = encoded);

      final decoded = decodePayload(captured!);
      expect(decoded.aiConfigs.single.token, 'the-secret');
      expect(sender.selectDelta(peer).aiConfigs, isEmpty);
    });

    test('push does not read the secret store for a private tuple', () async {
      final id = newUuidV7();
      seed(uuid: id, shared: false);
      tokens.seed(id, 'never-sent');

      await sender.push(peer, (_) async {});

      expect(tokens.readCalls, 0,
          reason: 'selection reads no token, and a private tuple is not '
              'selected at all');
    });
  });

  group('AC9/AC22 — codec round-trip and no secret in error text', () {
    test('encode/decode preserves a shared token and an unshared null', () {
      final sharedId = newUuidV7();
      final privateId = newUuidV7();
      final payload = SyncPayload(
        publications: const [],
        deletes: const [],
        aiConfigs: [
          AiConfigDto(
            uuid: sharedId,
            label: 'shared',
            endpoint: 'http://a',
            shared: true,
            token: 'tok',
            version: const VersionDto(counter: 1, deviceId: 'd-me'),
          ),
          AiConfigDto(
            uuid: privateId,
            label: 'private',
            endpoint: 'http://b',
            shared: false,
            version: const VersionDto(counter: 2, deviceId: 'd-me'),
          ),
        ],
      );

      final decoded = decodePayload(encodePayload(payload));
      expect(decoded.aiConfigs, hasLength(2));
      expect(decoded.aiConfigs[0].token, 'tok');
      expect(decoded.aiConfigs[1].token, isNull);
      expect(decoded.aiConfigs[1].shared, isFalse);
    });

    test('a malformed config uuid is refused without leaking the token', () {
      const sentinel = 'sk-sentinel-TOKEN';
      final payload = SyncPayload(
        publications: const [],
        deletes: const [],
        aiConfigs: [
          AiConfigDto(
            uuid: 'not-a-uuid',
            label: 'x',
            endpoint: 'http://a',
            shared: true,
            token: sentinel,
            version: const VersionDto(counter: 1, deviceId: 'd-me'),
          ),
        ],
      );

      expect(
        () => encodePayload(payload),
        throwsA(
          isA<SyncPayloadException>().having(
            (e) => e.toString().contains(sentinel),
            'leaks the token',
            isFalse,
          ),
        ),
      );
    });
  });
}

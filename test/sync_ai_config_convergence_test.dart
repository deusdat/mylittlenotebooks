import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_ai_config.dart';
import 'package:mylittlenotebooks/data/objectbox/objectbox_store.dart';
import 'package:mylittlenotebooks/data/objectbox_ai_config_repository.dart';
import 'package:mylittlenotebooks/data/sync/push_sender.dart';
import 'package:mylittlenotebooks/data/sync/sync_apply.dart';
import 'package:mylittlenotebooks/data/sync/sync_tombstones.dart';
import 'package:mylittlenotebooks/objectbox.g.dart';

import 'sync_test_fixtures.dart';
import 'test_token_store.dart';

/// Two-store convergence for shared tuples (settings-for-ai AC24).
///
/// In-process, in-memory, fakes only — no network, no keychain (NFR3, AC23).
void main() {
  late Peer a;
  late Peer b;

  setUp(() {
    a = Peer('d-a', 'ai-config-conv-a');
    b = Peer('d-b', 'ai-config-conv-b');
  });

  tearDown(() {
    a.dispose();
    b.dispose();
  });

  test('AC24: share, unshare and delete converge across two devices', () async {
    // 1. Create and share on A.
    final created = await a.repo.create(
      label: 'Shared',
      endpoint: 'https://api.example/v1',
      shared: true,
      token: 'secret-a',
    );

    await a.pushTo(b);

    expect(b.row(created.uuid), isNotNull);
    expect(b.row(created.uuid)!.shared, isTrue);
    expect(b.tokens.valueOf(created.uuid), 'secret-a');
    expect(a.tokens.valueOf(created.uuid), 'secret-a');

    // 2. Unshare on A: B must drop its copy, A keeps its own row.
    await a.repo.update(
      created.uuid,
      label: 'Shared',
      endpoint: 'https://api.example/v1',
      shared: false,
    );

    await a.pushTo(b);

    expect(a.row(created.uuid), isNotNull,
        reason: 'unsharing is private, not deleted');
    expect(a.row(created.uuid)!.shared, isFalse);
    expect(b.row(created.uuid), isNull);
    expect(b.tokens.has(created.uuid), isFalse);

    // 3. Delete on A: both must end with neither row nor secret.
    await a.repo.delete(created.uuid);

    await a.pushTo(b);

    expect(a.row(created.uuid), isNull);
    expect(b.row(created.uuid), isNull);
    expect(a.tokens.has(created.uuid), isFalse);
    expect(b.tokens.has(created.uuid), isFalse);
    expect(a.isDead(created.uuid), isTrue);
    expect(b.isDead(created.uuid), isTrue);
  });
}

/// One device: a store, its secret store, and the two sync entry points.
class Peer {
  Peer(this.deviceId, String tag) : store = openTestStore(tag) {
    tokens = FakeTokenStore();
    repo = ObjectBoxAiConfigRepository(store, tokens);
    sender = PushSender(store: store, deviceId: deviceId, tokens: tokens);
    applier = SyncApplier(
      store: store,
      activeEmbeddingModelId: testModel,
      deviceId: deviceId,
      tokens: tokens,
    );
  }

  final String deviceId;
  final Store store;
  late final FakeTokenStore tokens;
  late final ObjectBoxAiConfigRepository repo;
  late final PushSender sender;
  late final SyncApplier applier;

  Future<void> pushTo(Peer peer) => sender.push(
        peer.deviceId,
        (encoded) async => peer.applier.ingestEncoded(encoded),
      );

  ObAiConfig? row(String uuid) => store
      .box<ObAiConfig>()
      .query(ObAiConfig_.uuid.equals(uuid))
      .build()
      .findFirst();

  bool isDead(String uuid) => TombstoneStore(store).isDead(uuid);

  void dispose() => store.close();
}

import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/data/objectbox/objectbox_store.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_chunk.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_document.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_notebook.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_publication.dart';
import 'package:mylittlenotebooks/data/objectbox_library_repository.dart';
import 'package:mylittlenotebooks/data/objectbox_notebook_repository.dart';
import 'package:mylittlenotebooks/data/sync/push_sender.dart';
import 'package:mylittlenotebooks/data/sync/sync_apply.dart';
import 'package:mylittlenotebooks/data/sync/sync_codec.dart';
import 'package:mylittlenotebooks/data/sync/sync_deleter.dart';
import 'package:mylittlenotebooks/data/sync/sync_payload.dart';
import 'package:mylittlenotebooks/data/sync/sync_tombstones.dart';
import 'package:mylittlenotebooks/models/chunk.dart';
import 'package:mylittlenotebooks/objectbox.g.dart';

import 'sync_test_fixtures.dart';

/// Delete-notebook: the local cascade, the receiver branch, and the guards.
void main() {
  const me = 'd-me';
  const peer = 'd-peer';

  late Store store;
  late ObjectBoxLibraryRepository library;
  late ObjectBoxNotebookRepository notebooks;
  late TombstoneStore tombstones;
  late PushSender sender;

  setUp(() {
    store = openTestStore('del-nb');
    library = ObjectBoxLibraryRepository(store);
    notebooks = ObjectBoxNotebookRepository(store);
    tombstones = TombstoneStore(store);
    sender = PushSender(store: store, deviceId: me, tombstones: tombstones);
  });

  tearDown(() => store.close());

  /// A notebook with an exclusive and a shared publication, each with chunks.
  /// Returns (notebook uuid, exclusive publication uuid, shared publication uuid).
  ({String notebook, String exclusive, String shared}) seedNotebook() {
    final notebook = notebooks.create().id;
    final keeper = notebooks.create().id;

    final exclusive = library.create(
      title: 'Exclusive',
      sourceMarkdown: 'exclusive body',
      embeddingModelId: testModel,
    );
    final shared = library.create(
      title: 'Shared',
      sourceMarkdown: 'shared body',
      embeddingModelId: testModel,
    );
    library
      ..attach(exclusive.uuid, notebook)
      ..attach(shared.uuid, notebook)
      ..attach(shared.uuid, keeper)
      ..replaceChunks(exclusive.uuid, [
        for (var i = 0; i < 2; i++) draftChunk(i),
      ])
      ..replaceChunks(shared.uuid, [draftChunk(0)]);
    return (notebook: notebook, exclusive: exclusive.uuid, shared: shared.uuid);
  }

  group('T4 — local notebook delete', () {
    test('tombstones the notebook and its exclusive publication, not the shared', () {
      final seeded = seedNotebook();
      SyncDeleter(store: store, deviceId: me, tombstones: tombstones)
          .deleteNotebookLocally(seeded.notebook);

      expect(tombstones.isDead(seeded.notebook), isTrue);
      expect(tombstones.isDead(seeded.exclusive), isTrue);
      expect(
        tombstones.isDead(seeded.shared),
        isFalse,
        reason: 'a shared publication must not be tombstoned',
      );
    });

    test('the delete is selected into the next delta (AC4)', () {
      final seeded = seedNotebook();
      // Push everything once, so the watermarks are up to date.
      sender.acknowledge(peer, sender.selectDelta(peer));

      SyncDeleter(store: store, deviceId: me, tombstones: tombstones)
          .deleteNotebookLocally(seeded.notebook);

      final delta = sender.selectDelta(peer);
      final deleted = delta.deletes.map((d) => d.uuid).toSet();
      expect(deleted, contains(seeded.notebook));
      expect(deleted, contains(seeded.exclusive));
      expect(deleted, isNot(contains(seeded.shared)));
    });

    test('a fault after the cascade rolls back rows and tombstones (AC5)', () {
      final seeded = seedNotebook();
      final before = storeSnapshot(store);

      expect(
        () => SyncDeleter(
          store: store,
          deviceId: me,
          tombstones: tombstones,
          faultHook: () => throw StateError('injected'),
        ).deleteNotebookLocally(seeded.notebook),
        throwsA(isA<StateError>()),
      );

      expect(storeSnapshot(store), before);
      expect(tombstones.isDead(seeded.notebook), isFalse);
      expect(store.box<ObNotebook>().query().build().find().length, 2);
    });

    test('deleting twice is an idempotent no-op', () {
      final seeded = seedNotebook();
      final deleter = SyncDeleter(store: store, deviceId: me, tombstones: tombstones);
      deleter.deleteNotebookLocally(seeded.notebook);
      final afterFirst = storeSnapshot(store);

      deleter.deleteNotebookLocally(seeded.notebook);
      expect(storeSnapshot(store), afterFirst);
    });
  });

  group('T7 — receive branching and guards', () {
    test('a notebook delete removes the notebook and tombstones it', () {
      final notebook = notebooks.create().id;
      final delete = DeleteDto(uuid: notebook, version: testVersion(9, me));

      SyncApplier(
        store: store,
        activeEmbeddingModelId: testModel,
        deviceId: peer,
        tombstones: tombstones,
      ).ingest(SyncPayload(
        notebooks: const [],
        publications: const [],
        deletes: [delete],
      ));

      expect(
        store.box<ObNotebook>().query(ObNotebook_.uuid.equals(notebook)).build().find(),
        isEmpty,
      );
      expect(tombstones.isDead(notebook), isTrue);
    });

    test('a delete for an unknown notebook is a no-op that still tombstones (AC9)', () {
      const missing = 'nb-never-seen';
      SyncApplier(
        store: store,
        activeEmbeddingModelId: testModel,
        deviceId: peer,
        tombstones: tombstones,
      ).ingest(SyncPayload(
        notebooks: const [],
        publications: const [],
        deletes: [DeleteDto(uuid: missing, version: testVersion(4, me))],
      ));

      expect(tombstones.isDead(missing), isTrue);
      expect(store.box<ObNotebook>().count(), 0);
    });

    test('a tombstoned notebook rejects a higher-version record (AC10)', () {
      final notebook = notebooks.create().id;
      // Simulate a prior delete: the row is gone and the uuid is dead.
      store
          .box<ObNotebook>()
          .query(ObNotebook_.uuid.equals(notebook))
          .build()
          .remove();
      tombstones.markDead(notebook, versionCounter: 1);

      SyncApplier(
        store: store,
        activeEmbeddingModelId: testModel,
        deviceId: peer,
        tombstones: tombstones,
      ).ingest(SyncPayload(
        notebooks: [
          NotebookDto(
            uuid: notebook,
            title: 'Resurrected',
            // Strictly higher than the death version. FR14: still refused.
            version: testVersion(999, me),
          ),
        ],
        publications: const [],
        deletes: const [],
      ));

      expect(store.box<ObNotebook>().count(), 0);
    });

    test('a dead edge is dropped, not resurrected (AC11)', () {
      const deadNotebook = 'nb-dead';
      tombstones.markDead(deadNotebook, versionCounter: 3);
      final alive = notebooks.create().id;
      final publication = library.create(
        title: 'Arriving',
        sourceMarkdown: 'body',
        embeddingModelId: testModel,
      );
      library.detach(publication.uuid, alive);

      SyncApplier(
        store: store,
        activeEmbeddingModelId: testModel,
        deviceId: peer,
        tombstones: tombstones,
      ).ingest(SyncPayload(
        notebooks: [
          NotebookDto(uuid: alive, title: 'Alive', version: testVersion(1, me)),
        ],
        publications: [
          testPublication(
            uuid: publication.uuid,
            count: 1,
            notebookUuids: [deadNotebook, alive],
          ),
        ],
        deletes: const [],
      ));

      expect(
        store.box<ObNotebook>().query(ObNotebook_.uuid.equals(deadNotebook)).build().find(),
        isEmpty,
        reason: 'a tombstoned notebook must not be materialised by an edge',
      );
      final row = store
          .box<ObNotebook>()
          .query(ObNotebook_.uuid.equals(alive))
          .build()
          .findFirst()!;
      expect(row.publications.map((p) => p.uuid), [publication.uuid]);
    });

    test('a cascaded publication tombstone rejects a higher-version upsert (AC12)', () {
      const deadPub = 'pub-dead';
      tombstones.markDead(deadPub, versionCounter: 2);

      SyncApplier(
        store: store,
        activeEmbeddingModelId: testModel,
        deviceId: peer,
        tombstones: tombstones,
      ).ingest(SyncPayload(
        notebooks: const [],
        publications: [testPublication(uuid: deadPub, count: 1)],
        deletes: const [],
      ));

      expect(
        store.box<ObPublication>().query(ObPublication_.uuid.equals(deadPub)).build().find(),
        isEmpty,
      );
    });

    test('a notebook delete payload contains no tombstone or type field (AC6)', () {
      final seeded = seedNotebook();
      SyncDeleter(store: store, deviceId: me, tombstones: tombstones)
          .deleteNotebookLocally(seeded.notebook);

      final encoded = encodePayload(sender.selectDelta(peer));
      expect(encoded, contains('"deletes"'));
      expect(
        RegExp('tombstone', caseSensitive: false).hasMatch(encoded),
        isFalse,
      );
      expect(encoded, isNot(contains('entityType')));
    });

    test('a publication delete still cascades as before', () {
      final publication = library.create(
        title: 'Doomed',
        sourceMarkdown: 'body',
        embeddingModelId: testModel,
      );
      library.replaceChunks(publication.uuid, [draftChunk(0), draftChunk(1)]);

      SyncApplier(
        store: store,
        activeEmbeddingModelId: testModel,
        deviceId: peer,
        tombstones: tombstones,
      ).ingest(SyncPayload(
        notebooks: const [],
        publications: const [],
        deletes: [DeleteDto(uuid: publication.uuid, version: testVersion(9, me))],
      ));

      expect(store.box<ObPublication>().count(), 0);
      expect(store.box<ObChunk>().count(), 0);
      expect(store.box<ObDocument>().count(), 0);
      expect(tombstones.isDead(publication.uuid), isTrue);
    });
  });
}

/// A chunk draft (`ChunkDraft` lives in models/chunk.dart).
ChunkDraft draftChunk(int index) => ChunkDraft(
      chunkIndex: index,
      content: 'chunk $index',
      tokenCount: 3,
      embedding: unitVector(index),
    );

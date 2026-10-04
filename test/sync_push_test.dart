import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/data/identity.dart';
import 'package:mylittlenotebooks/data/objectbox/objectbox_store.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_chunk.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_notebook.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_publication.dart';
import 'package:mylittlenotebooks/data/objectbox_library_repository.dart';
import 'package:mylittlenotebooks/data/sync/push_sender.dart';
import 'package:mylittlenotebooks/data/sync/sync_apply.dart';
import 'package:mylittlenotebooks/data/sync/sync_codec.dart';
import 'package:mylittlenotebooks/data/sync/sync_payload.dart';
import 'package:mylittlenotebooks/data/sync/sync_tombstones.dart';
import 'package:mylittlenotebooks/models/chunk.dart';
import 'package:mylittlenotebooks/objectbox.g.dart';

import 'sync_test_fixtures.dart';

void main() {
  const peer = 'd-peer';

  late Store store;
  late ObjectBoxLibraryRepository library;
  late PushSender sender;
  late TombstoneStore tombstones;

  setUp(() {
    store = openTestStore('push');
    library = ObjectBoxLibraryRepository(store);
    tombstones = TombstoneStore(store);
    sender = PushSender(store: store, deviceId: 'd-me', tombstones: tombstones);
  });

  tearDown(() => store.close());

  Box<ObPublication> pubs() => store.box<ObPublication>();

  ObPublication pubByUuid(String uuid) =>
      pubs().query(ObPublication_.uuid.equals(uuid)).build().findFirst()!;

  String indexedPublication({
    String? title = 'Indexed',
    String? uuid,
    int chunkCount = 4,
  }) {
    final created = library.create(
      title: title!,
      sourceMarkdown: 'the body',
      embeddingModelId: testModel,
    );
    library.replaceChunks(
      created.uuid,
      [for (var i = 0; i < chunkCount; i++) draft(i)],
    );
    return uuid ?? created.uuid;
  }

  group('FR11 — a delta, not a corpus', () {
    test('a peer with no watermark receives everything', () {
      indexedPublication(chunkCount: 3);

      final delta = sender.selectDelta(peer);

      expect(delta.publications, hasLength(1));
      expect(delta.publications.single.chunks, hasLength(3),
          reason: 'the first push must carry the corpus; "no watermark" means '
              'everything, not nothing');
    });

    test('an acknowledged watermark stops the flow', () {
      final uuid = indexedPublication(chunkCount: 3);
      sender.acknowledge(peer, sender.selectDelta(peer));

      expect(sender.selectDelta(peer).publications, isEmpty);
      expect(pubByUuid(uuid).chunkCount, 3, reason: 'and nothing was deleted');
    });

    test('a new edit reappears in the next delta', () {
      final uuid = indexedPublication(chunkCount: 3);
      sender.acknowledge(peer, sender.selectDelta(peer));
      expect(sender.selectDelta(peer).publications, isEmpty);

      library.attach(uuid, notebookUuid(store, 'Later'));

      expect(sender.selectDelta(peer).publications, hasLength(1));
    });

    test('watermarks are per peer, not global', () {
      indexedPublication(chunkCount: 2);
      final first = indexedPublication(chunkCount: 2);

      sender.acknowledge('d-one', sender.selectDelta('d-one'));

      // The second peer has never been pushed to, so it needs everything —
      // including the publication the first peer already has.
      expect(sender.selectDelta('d-one').publications, isEmpty);
      expect(sender.selectDelta('d-two').publications.map((p) => p.uuid),
          containsAll([first]));
    });

    test('an older acknowledgement never moves a watermark backwards', () {
      final uuid = indexedPublication(chunkCount: 2);
      final first = sender.selectDelta(peer);
      sender.acknowledge(peer, first);
      final afterFirst = sender.sentTo(peer, uuid)!;

      // A straggling acknowledgement from an interrupted earlier attempt.
      sender.acknowledge(peer, SyncPayload(
        publications: [
          PublicationDto(
            uuid: uuid,
            title: 'Stale',
            byteSize: 0,
            embeddingModelId: testModel,
            declaredChunkCount: 0,
            chunksIncluded: false,
            version: testVersion(0),
            chunkSetVersion: testVersion(0),
            notebookUuids: const [],
          ),
        ],
        deletes: const [],
      ));

      expect(sender.sentTo(peer, uuid), afterFirst,
          reason: 'otherwise a permanent re-send loop: every interrupted attempt '
              'unwinds the cursor and the next one sends the same range again');
    });
  });

  group('FR5a — metadata and chunk set are selected separately', () {
    test('AC7c: a retitle transfers metadata and no chunks', () {
      final uuid = indexedPublication(chunkCount: 5);
      sender.acknowledge(peer, sender.selectDelta(peer));

      retitle(store, uuid, 'Renamed');

      final delta = sender.selectDelta(peer);
      final dto = delta.publications.single;
      expect(dto.title, 'Renamed');
      expect(dto.chunks, isEmpty, reason: 'a rename must not ship the corpus');
      expect(dto.chunksIncluded, isFalse,
          reason: 'and it must SAY so — see the `chunksIncluded` note');
    });

    test('AC7c: a re-index then transfers the full replacement set', () {
      final uuid = indexedPublication(chunkCount: 5);
      sender.acknowledge(peer, sender.selectDelta(peer));

      library.replaceChunks(uuid, [for (var i = 0; i < 7; i++) draft(i, seed: i)]);

      final dto = sender.selectDelta(peer).publications.single;
      expect(dto.chunksIncluded, isTrue);
      expect(dto.chunks, hasLength(7));
      expect(dto.declaredChunkCount, 7);
    });

    test('a metadata-only push does not declare a chunk count it is not sending',
        () {
      final uuid = indexedPublication(chunkCount: 5);
      sender.acknowledge(peer, sender.selectDelta(peer));
      retitle(store, uuid, 'Renamed');

      final dto = sender.selectDelta(peer).publications.single;
      // Declaring the publication's real count of 5 while sending none would
      // look exactly like the truncation FR5a-bis exists to catch, and the
      // receiver would refuse the payload.
      expect(dto.declaredChunkCount, 0);
      expect(dto.chunks, isEmpty);
    });

    test('the receiving end honours chunksIncluded and keeps its own set', () {
      // The failure this prevents: a metadata-only push replaces the receiver's
      // whole chunk set with nothing, because the set version the payload
      // carries is the sender's current one and compares as newer than anything
      // the receiver holds. The sender has done nothing wrong; the receiver has
      // to know the set was not in the payload.
      final receiver = openTestStore('push-receiver');
      addTearDown(receiver.close);
      final applier = SyncApplier(
        store: receiver,
        activeEmbeddingModelId: testModel,
        deviceId: 'd-peer',
      );

      final uuid = indexedPublication(chunkCount: 5);
      final firstPush = sender.selectDelta(peer);
      applier.ingest(firstPush);
      sender.acknowledge(peer, firstPush);
      expect(receiver.box<ObChunk>().count(), 5);

      retitle(store, uuid, 'Renamed on the sender');
      final renameDelta = sender.selectDelta(peer);
      expect(renameDelta.publications.single.chunksIncluded, isFalse);

      applier.ingest(renameDelta);

      expect(receiver.box<ObChunk>().count(), 5,
          reason: 'a metadata-only push must not wipe the chunk set');
      final stored = receiver.box<ObPublication>().getAll().single;
      expect(stored.title, 'Renamed on the sender');
      expect(stored.chunkCount, 5);
    });
  });

  group('AC5 — a repeated push changes nothing', () {
    test('pushing the same range twice produces identical bytes', () {
      indexedPublication(chunkCount: 4);

      final first = encodePayload(sender.selectDelta(peer));
      final second = encodePayload(sender.selectDelta(peer));

      expect(second, first,
          reason: 'idempotency has to hold at the byte level, or a re-push '
              'after an interruption is a different payload rather than the '
              'same one');
    });

    test('the receiver ends in the same state after one push and after two',
        () async {
      final receiver = openTestStore('push-ac5');
      addTearDown(receiver.close);
      final applier = SyncApplier(
        store: receiver,
        activeEmbeddingModelId: testModel,
        deviceId: 'd-peer',
      );
      indexedPublication(chunkCount: 4);
      final encoded = encodePayload(sender.selectDelta(peer));

      await applier.ingestEncoded(encoded);
      final afterOne = storeSnapshot(receiver);
      await applier.ingestEncoded(encoded);
      final afterTwo = storeSnapshot(receiver);

      expect(afterTwo, afterOne);
    });

    test('after acknowledgement the next delta is empty', () async {
      indexedPublication(chunkCount: 4);

      await sender.push(peer, (_) async {});
      expect(sender.selectDelta(peer).publications, isEmpty);
    });
  });

  group('plan R7 — the watermark advances only on acknowledgement', () {
    test('an interrupted push records nothing', () async {
      final uuid = indexedPublication(chunkCount: 4);

      await expectLater(
        sender.push(peer, (_) async => throw StateError('the link dropped')),
        throwsStateError,
      );

      expect(sender.sentTo(peer, uuid), isNull,
          reason: 'nothing was acknowledged, so nothing may be remembered');
      expect(sender.recordsSentTo(peer), 0);
    });

    test('a re-push after an interruption delivers the identical full range',
        () async {
      indexedPublication(chunkCount: 4);
      final attempted = <String>[];

      await expectLater(
        sender.push(peer, (encoded) async {
          attempted.add(encoded);
          throw StateError('the link dropped');
        }),
        throwsStateError,
      );
      await sender.push(peer, (encoded) async => attempted.add(encoded));

      expect(attempted, hasLength(2));
      expect(attempted[1], attempted[0],
          reason: 'the retry must be the same range, not a shorter one');
      expect(decodePayload(attempted[1]).publications.single.chunks, hasLength(4));
    });

    test('a push advances the watermark only after the peer confirms', () async {
      final uuid = indexedPublication(chunkCount: 2);

      await sender.push(peer, (encoded) async {
        // Mid-transfer nothing is recorded: the peer has not confirmed yet.
        expect(sender.sentTo(peer, uuid), isNull);
      });

      expect(sender.sentTo(peer, uuid), isNotNull);
    });
  });

  group('deletes travel', () {
    test('a local delete appears in the next delta', () {
      final uuid = indexedPublication(chunkCount: 3);
      sender.acknowledge(peer, sender.selectDelta(peer));

      final applier = SyncApplier(
        store: store,
        activeEmbeddingModelId: testModel,
        deviceId: 'd-me',
        tombstones: tombstones,
      );
      applier.deleteLocally(uuid);

      final delta = sender.selectDelta(peer);
      expect(delta.deletes.map((d) => d.uuid), [uuid]);
      expect(delta.publications, isEmpty);
    });

    test('an acknowledged delete is not re-sent', () {
      final uuid = indexedPublication(chunkCount: 2);
      final applier = SyncApplier(
        store: store,
        activeEmbeddingModelId: testModel,
        deviceId: 'd-me',
        tombstones: tombstones,
      );
      applier.deleteLocally(uuid);
      sender.acknowledge(peer, sender.selectDelta(peer));

      expect(sender.selectDelta(peer).deletes, isEmpty);
    });

    test('no tombstones travel — only the delete record', () {
      final uuid = indexedPublication(chunkCount: 2);
      SyncApplier(
        store: store,
        activeEmbeddingModelId: testModel,
        deviceId: 'd-me',
        tombstones: tombstones,
      ).deleteLocally(uuid);

      final encoded = encodePayload(sender.selectDelta(peer));
      expect(encoded, contains('"deletes"'));
      // FR13: a tombstone is local state. What crosses the wire is a uuid and a
      // version; the word must not appear as a field.
      expect(RegExp('tombstone', caseSensitive: false).hasMatch(encoded), isFalse);
      expect(encoded, isNot(contains('deletedAt')));
    });

    test('a delete round-trips between two devices', () {
      final uuid = indexedPublication(chunkCount: 3);
      sender.acknowledge(peer, sender.selectDelta(peer));
      SyncApplier(
        store: store,
        activeEmbeddingModelId: testModel,
        deviceId: 'd-me',
        tombstones: tombstones,
      ).deleteLocally(uuid);

      final receiver = openTestStore('push-del');
      addTearDown(receiver.close);
      final receiverTombstones = TombstoneStore(receiver);
      SyncApplier(
        store: receiver,
        activeEmbeddingModelId: testModel,
        deviceId: 'd-peer',
        tombstones: receiverTombstones,
      ).ingest(sender.selectDelta(peer));

      expect(receiver.box<ObPublication>().getAll(), isEmpty);
      expect(receiver.box<ObChunk>().count(), 0);
      expect(receiverTombstones.isDead(uuid), isTrue);
    });
  });

  group('the measured size of a delta (T17 step 4)', () {
    test('a first push of a realistic corpus is measured, not estimated', () {
      // The Revision 2 record quotes a first-push cost. This is the figure, so
      // the number in the spec is a measurement rather than an arithmetic
      // exercise.
      for (var p = 0; p < 10; p++) {
        final uuid = indexedPublication(title: 'Publication $p', chunkCount: 300);
        library.attach(uuid, notebookUuid(store, 'Corpus'));
      }

      final delta = sender.selectDelta(peer);
      final bytes = encodedLengthOf(delta);

      // ignore: avoid_print
      print('DELTA first push: ${delta.publications.length} publications, '
          '${delta.publications.fold<int>(0, (a, p) => a + p.chunks.length)} chunks, '
          '$bytes bytes');

      expect(delta.publications, hasLength(10));
      expect(bytes, greaterThan(0));
    });

    test('a retitle-only delta is tiny next to a first push', () {
      final uuid = indexedPublication(chunkCount: 300);
      // Measured *before* acknowledging — after it, the delta is empty and the
      // ratio would compare a rename against nothing.
      final firstPush = encodedLengthOf(sender.selectDelta(peer));
      sender.acknowledge(peer, sender.selectDelta(peer));

      retitle(store, uuid, 'Renamed');
      final renameDelta = encodedLengthOf(sender.selectDelta(peer));

      // ignore: avoid_print
      print('DELTA retitle: $renameDelta bytes against a $firstPush byte '
          'first push (${(renameDelta * 100 / firstPush).toStringAsFixed(2)}%)');

      expect(renameDelta, lessThan(firstPush ~/ 10),
          reason: 'this ratio is the whole point of the two-version split');
    });
  });
}

/// Renames a publication the way the app would: a metadata edit only.
/// Renames a publication the way the app would: metadata only.
///
/// The data layer has no retitle operation — a title is set at import and there
/// is no UI for changing one — so this drives the entity directly. What matters
/// is that it moves **only** the metadata version, exactly as plan §G specifies,
/// because that is what the delta selection reads.
void retitle(Store store, String uuid, String title) {
  final box = store.box<ObPublication>();
  final row = box.query(ObPublication_.uuid.equals(uuid)).build().findFirst()!;
  row.title = title;
  row.versionCounter++;
  box.put(row);
}

String notebookUuid(Store store, String title) {
  final box = store.box<ObNotebook>();
  final existing = box.query().build();
  try {
    for (final notebook in existing.find()) {
      if (notebook.title == title) return notebook.uuid;
    }
  } finally {
    existing.close();
  }
  final created = ObNotebook(
    uuid: newUuidV7(),
    title: title,
    createdAt: DateTime.now().toUtc(),
  );
  box.put(created);
  return created.uuid;
}

/// A deterministic chunk draft, for seeding local state.
ChunkDraft draft(int index, {int seed = 0}) => ChunkDraft(
      chunkIndex: index,
      content: 'chunk $index',
      tokenCount: 4,
      embedding: seededVector(seed + index),
    );

List<double> seededVector(int seed) {
  final random = Random(seed);
  final values = List<double>.filled(256, 0);
  for (var i = 0; i < 256; i++) {
    values[i] = random.nextDouble() - 0.5;
  }
  final norm = sqrt(values.fold<double>(0, (a, b) => a + b * b));
  return values.map((v) => v / norm).toList();
}

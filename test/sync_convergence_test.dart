import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/data/identity.dart';
import 'package:mylittlenotebooks/data/objectbox/objectbox_store.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_chunk.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_document.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_notebook.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_publication.dart';
import 'package:mylittlenotebooks/data/objectbox_library_repository.dart';
import 'package:mylittlenotebooks/data/sync/push_sender.dart';
import 'dart:isolate';

import 'package:mylittlenotebooks/data/sync/sync_apply.dart';
import 'package:mylittlenotebooks/data/sync/sync_codec.dart';
import 'package:mylittlenotebooks/data/sync/sync_deleter.dart';
import 'package:mylittlenotebooks/data/sync/sync_payload.dart';
import 'package:mylittlenotebooks/data/sync/sync_tombstones.dart';
import 'package:mylittlenotebooks/models/chunk.dart';
import 'package:mylittlenotebooks/objectbox.g.dart';

import 'sync_test_fixtures.dart';

/// Two devices, two stores, one link. No network, no emulator, no fixture files
/// (NFR4, AC15) — the whole protocol is exercisable in-process, which is the only
/// reason it can be tested at all before there is a transport.
void main() {
  group('two devices converge', () {
    late Device laptop;
    late Device phone;

    setUp(() {
      laptop = Device('converge-laptop', 'd-laptop');
      phone = Device('converge-phone', 'd-phone');
      addTearDown(laptop.dispose);
      addTearDown(phone.dispose);
    });

    test('AC11: a corpus created on one device reaches the other intact', () async {
      final notebook = laptop.createNotebook('Research');
      for (var i = 0; i < 3; i++) {
        laptop.createPublication(
          title: 'Paper $i',
          body: '# Paper $i\n\nbody $i',
          chunkCount: 2 + i,
          notebook: notebook,
        );
      }

      await laptop.pushTo(phone);

      expect(storeSnapshot(laptop.store), storeSnapshot(phone.store),
          reason: 'including every vector, which revision 1 could not claim and '
              'which is the practical reason chunks travel at all');
    });

    test('AC11: concurrent edits on both sides settle on one answer', () async {
      final notebook = laptop.createNotebook('Shared');
      final uuid = laptop.createPublication(
          title: 'Original', body: 'original body', notebook: notebook);
      await laptop.pushTo(phone);

      // Both devices edit the same publication without seeing each other.
      laptop.rename(uuid, 'Edited on the laptop');
      phone.rename(uuid, 'Edited on the phone');

      await converge(laptop, phone);

      expect(phone.read(uuid).title, laptop.read(uuid).title,
          reason: 'the tie must break the same way on both sides — that is what '
              'the total order over (counter, deviceId) buys');
      expect(laptop.read(uuid).title, 'Edited on the phone',
          reason: '"d-phone" > "d-laptop", so the phone wins an equal-counter tie');
    });

    test('a re-index on one side replaces the set on the other', () async {
      final uuid = laptop.createPublication(
          title: 'Reindexed', body: 'body', chunkCount: 4);
      await laptop.pushTo(phone);

      laptop.reindex(uuid, 9);

      await converge(laptop, phone);
      expect(phone.chunksOf(uuid), hasLength(9));
      expect(phone.read(uuid).chunkCount, 9);
    });

    test('a shrinking set leaves nothing behind on the other side', () async {
      final uuid = laptop.createPublication(
          title: 'Shrinking', body: 'body', chunkCount: 20);
      await laptop.pushTo(phone);
      expect(phone.chunksOf(uuid), hasLength(20));

      laptop.reindex(uuid, 3);
      await converge(laptop, phone);

      expect(phone.chunksOf(uuid), hasLength(3));
      expect(phone.read(uuid).chunkCount, 3);
    });

    test('a tombstone racing an in-flight upsert ends deleted', () async {
      final uuid = laptop.createPublication(
          title: 'Doomed', body: 'body', chunkCount: 3);
      await laptop.pushTo(phone);

      // The laptop deletes while the phone still holds the publication and is
      // pushing a stale copy back at the same moment.
      final staleUpsert = laptop.sender.selectDelta(phone.deviceId);
      laptop.delete(uuid);

      phone.applier.ingest(staleUpsert);
      await laptop.pushTo(phone);

      expect(phone.readOrNull(uuid), isNull);
      expect(phone.chunksOf(uuid), isEmpty,
          reason: 'FR14: a tombstone beats any live record, and the upsert that '
              'was in flight is no exception');
      expect(phone.tombstones.isDead(uuid), isTrue);
    });

    test('a delete on one side stays deleted after further pushes', () async {
      final uuid = laptop.createPublication(
          title: 'Gone', body: 'body', chunkCount: 2);
      await laptop.pushTo(phone);
      laptop.delete(uuid);
      await converge(laptop, phone);

      expect(phone.readOrNull(uuid), isNull);
      await laptop.pushTo(phone);
      expect(phone.readOrNull(uuid), isNull,
          reason: 'and a later push must not resurrect it');
    });

    test('a chunk set replaced while a metadata edit is in flight', () async {
      final uuid = laptop.createPublication(
          title: 'Original', body: 'body', chunkCount: 4);
      await laptop.pushTo(phone);

      // Simultaneous and unrelated: a re-index on one side, a rename on the
      // other. Neither saw the other. Both must survive.
      laptop.reindex(uuid, 7);
      phone.rename(uuid, 'Renamed on the phone');

      await converge(laptop, phone);

      expect(laptop.read(uuid).title, phone.read(uuid).title);
      expect(phone.read(uuid).title, 'Renamed on the phone');
      expect(laptop.chunksOf(uuid), hasLength(7),
          reason: 'the rename must not have displaced the re-index');
      expect(phone.chunksOf(uuid), hasLength(7));
    });

    test('a peer on a different embedding model keeps the document, not the vectors',
        () async {
      phone = Device('converge-stale-model', 'd-phone', model: 'other-model:v1');
      addTearDown(phone.dispose);

      final uuid = laptop.createPublication(
          title: 'Vectors', body: 'the body', chunkCount: 5);
      await laptop.pushTo(phone);

      expect(phone.readOrNull(uuid), isNotNull, reason: 'the metadata arrives');
      expect(phone.documentOf(uuid), 'the body',
          reason: 'the document is the user\'s data and transfers regardless');
      expect(phone.chunksOf(uuid), isEmpty,
          reason: 'and not one vector from a foreign model lands (FR5b)');

      // And the sender's own index is untouched by having pushed to a device
      // that could not accept it.
      expect(laptop.chunksOf(uuid), hasLength(5));
    });

    test('convergence is order-independent', () async {
      // Six records edited concurrently on both sides, then delivered in a
      // shuffled order. The final state must not depend on the shuffle — that is
      // what "records never land before their parent resolves" (FR7) buys, since
      // each DAG is independent and every decision is version-based.
      for (var i = 0; i < 6; i++) {
        final uuid =
            laptop.createPublication(title: 'Doc $i', body: 'body $i', chunkCount: 2);
        laptop.attach(uuid, laptop.createNotebook('N$i'));
        phone.ingestDirect(PublicationDto(
          uuid: uuid,
          title: 'Phone $i',
          byteSize: 10,
          embeddingModelId: testModel,
          declaredChunkCount: 2,
          chunksIncluded: true,
          version: VersionDto(counter: 2, deviceId: 'd-phone'),
          chunkSetVersion: VersionDto(counter: 1, deviceId: 'd-phone'),
          notebookUuids: [],
          chunks: [
            for (var c = 0; c < 2; c++)
              testChunk(uuid, c, seed: 100 + c),
          ],
        ));
      }

      final delta = laptop.sender.selectDelta(phone.deviceId);
      final inOrder = delta.publications.map((p) => p.uuid).toList();
      final shuffled = List<String>.of(inOrder)..shuffle(Random(7));
      expect(shuffled, isNot(inOrder), reason: 'the shuffle has to actually shuffle');

      phone.applier.ingest(SyncPayload(
        publications: [
          for (final uuid in shuffled)
            delta.publications.firstWhere((p) => p.uuid == uuid),
        ],
        deletes: delta.deletes,
      ));
      laptop.sender.acknowledge(phone.deviceId, delta);
      await converge(laptop, phone);

      expect(storeSnapshot(laptop.store), storeSnapshot(phone.store),
          reason: 'a shuffled delivery reached the same place as a sorted one');
    });

    test('an empty delta between two settled devices changes nothing', () async {
      laptop.createPublication(title: 'Only', body: 'body', chunkCount: 3);
      await converge(laptop, phone);

      final before = storeSnapshot(phone.store);
      await laptop.pushTo(phone);
      await phone.pushTo(laptop);

      expect(storeSnapshot(phone.store), before);
    });

    test('repeated exchanges are stable — convergence is a fixed point',
        () async {
      final uuid = laptop.createPublication(
          title: 'Churn', body: 'body', chunkCount: 3);
      await converge(laptop, phone);
      final settled = storeSnapshot(phone.store);

      for (var round = 0; round < 3; round++) {
        await converge(laptop, phone);
      }

      expect(storeSnapshot(phone.store), settled,
          reason: 'if a settled pair keeps trading deltas, something is being '
              're-sent forever');
      expect(laptop.read(uuid).title, 'Churn');
    });
  });

  group('NFR6 — a push is bounded and interruptible', () {
    late Device laptop;
    late Device phone;

    setUp(() {
      laptop = Device('nfr6-laptop', 'd-laptop');
      phone = Device('nfr6-phone', 'd-phone');
      addTearDown(laptop.dispose);
      addTearDown(phone.dispose);
    });

    test('the local store stays readable and writable throughout a push',
        () async {
      final uuid = laptop.createPublication(
          title: 'Busy', body: 'body', chunkCount: 5);
      var readsDuringPush = 0;
      var writesDuringPush = 0;

      await laptop.sender.push(phone.deviceId, (encoded) async {
        // Mid-transfer — between selection and acknowledgement — this device's
        // own store must be fully usable. A push that held a write lock, or ran
        // inside the transaction, would fail here rather than in production.
        readsDuringPush += laptop.chunksOf(uuid).length;
        readsDuringPush += laptop.read(uuid).chunkCount;

        laptop.rename(uuid, 'Edited during the push');
        writesDuringPush++;
      });

      expect(readsDuringPush, greaterThan(0));
      expect(writesDuringPush, 1);
      expect(laptop.read(uuid).title, 'Edited during the push');
    });

    test('a push can be abandoned partway and the device stays consistent',
        () async {
      final uuid = laptop.createPublication(
          title: 'Abandoned', body: 'body', chunkCount: 4);

      await expectLater(
        laptop.sender
            .push(phone.deviceId, (_) async => throw StateError('cancelled')),
        throwsStateError,
      );

      // Nothing half-applied on either side, and the sender will try again.
      expect(laptop.chunksOf(uuid), hasLength(4));
      expect(phone.store.box<ObChunk>().count(), 0);
      expect(laptop.sender.recordsSentTo(phone.deviceId), 0);

      // And the retry works.
      await laptop.pushTo(phone);
      expect(phone.chunksOf(uuid), hasLength(4));
    });

    test('encoding is isolate-safe, so the work can leave the UI isolate',
        () async {
      // Not a benchmark. The property being checked is that encoding a payload is
      // a pure function of its input — no captured state, no store handle, nothing
      // isolate-bound. Without that, moving a push off the UI isolate (NFR6) would
      // not be possible at all, and the requirement would be unmeetable rather than
      // merely unimplemented.
      laptop.createPublication(title: 'Isolated', body: 'body', chunkCount: 8);
      final payload = laptop.sender.selectDelta(phone.deviceId);

      final here = encodePayload(payload);
      // Spawned with the payload as a *message*, not captured from the enclosing
      // closure. A closure would drag the whole lexical context across with it —
      // including this device's `Store`, which is unsendable, and the failure would
      // be about capture rather than about encode.
      final elsewhere = await _encodeInIsolate(payload);

      expect(elsewhere, here,
          reason: 'the same input must encode to the same bytes in any isolate, '
              'or the transfer is not reproducible and AC5 is unverifiable');
    });

    test('a large delta encodes in bounded time', () {
      // Bounded, not fast. The point is that selection and encoding scale with
      // the corpus rather than with anything unbounded, so a push has a knowable
      // worst case instead of an open-ended one.
      for (var i = 0; i < 20; i++) {
        laptop.createPublication(
            title: 'Doc $i', body: 'body $i', chunkCount: 100);
      }

      final stopwatch = Stopwatch()..start();
      final payload = laptop.sender.selectDelta(phone.deviceId);
      final bytes = encodedLengthOf(payload);
      stopwatch.stop();

      final chunks = payload.publications.fold<int>(0, (a, p) => a + p.chunks.length);
      // ignore: avoid_print
      print('DELTA ${payload.publications.length} publications, $chunks chunks, '
          '$bytes bytes, selected and encoded in '
          '${stopwatch.elapsedMilliseconds}ms');

      expect(chunks, 2000);
      expect(stopwatch.elapsedMilliseconds, lessThan(15000),
          reason: 'generous, but it would catch an accidental quadratic');
    });
  });

  group('delete-notebook — a notebook and its exclusives converge', () {
    late Device laptop;
    late Device phone;

    setUp(() {
      laptop = Device('del-laptop', 'd-laptop');
      phone = Device('del-phone', 'd-phone');
      addTearDown(laptop.dispose);
      addTearDown(phone.dispose);
    });

    test('AC8: exclusive gone, shared survives, both stores identical', () async {
      final notebook = laptop.createNotebook('Doomed');
      final keeper = laptop.createNotebook('Keeper');
      final exclusive = laptop.createPublication(
        title: 'Exclusive',
        body: 'exclusive body',
        chunkCount: 2,
        notebook: notebook,
      );
      final shared = laptop.createPublication(
        title: 'Shared',
        body: 'shared body',
        chunkCount: 1,
        notebook: notebook,
      );
      laptop.attach(shared, keeper);

      // Reflect the whole corpus on the phone first.
      await laptop.pushTo(phone);
      expect(storeSnapshot(laptop.store), storeSnapshot(phone.store));

      // The user deletes the notebook on the laptop.
      laptop.deleteNotebook(notebook);

      await converge(laptop, phone);

      // Notebook gone on both; exclusive publication and its chunks gone.
      expect(phone.readOrNull(exclusive), isNull);
      expect(phone.chunksOf(exclusive), isEmpty);
      expect(
        phone.store
            .box<ObNotebook>()
            .query(ObNotebook_.uuid.equals(notebook))
            .build()
            .find(),
        isEmpty,
      );

      // Shared publication alive with its surviving edge and searchable.
      expect(phone.readOrNull(shared), isNotNull);
      expect(phone.read(shared).notebooks.map((n) => n.uuid), [keeper]);

      expect(
        storeSnapshot(laptop.store),
        storeSnapshot(phone.store),
        reason: 'the delete-notebook cascade must converge byte for byte',
      );
    });

    test('AC7: re-ingesting the delete changes nothing', () async {
      final notebook = laptop.createNotebook('Once');
      laptop.createPublication(
        title: 'Only',
        body: 'body',
        chunkCount: 1,
        notebook: notebook,
      );
      await laptop.pushTo(phone);

      laptop.deleteNotebook(notebook);
      final payload = laptop.sender.selectDelta(phone.deviceId);
      final encoded = encodePayload(payload);

      await phone.applier.ingestEncoded(encoded);
      final afterFirst = storeSnapshot(phone.store);
      await phone.applier.ingestEncoded(encoded);
      expect(storeSnapshot(phone.store), afterFirst);
    });
  });

  group('AC15 — nothing outside this process is involved', () {
    test('two stores, no files, no network', () {
      final a = Device('hermetic-a', 'd-a');
      final b = Device('hermetic-b', 'd-b');
      addTearDown(a.dispose);
      addTearDown(b.dispose);

      a.createPublication(title: 'X', body: 'y', chunkCount: 1);

      // The link is a function call. If this suite ever needed a socket, a
      // fixture directory, or an emulator, this would be where it showed up.
      // Both stores are live and independent: writing to one leaves the other
      // untouched until something is pushed.
      expect(a.store.box<ObPublication>().count(), 1);
      expect(b.store.box<ObPublication>().count(), 0);
      expect(storeSnapshot(a.store), isNot(storeSnapshot(b.store)));
    });
  });
}

/// Pushes in both directions until neither has anything left to say.
///
/// Two rounds rather than one: a single exchange can reveal a new edit made
/// while the first direction was in flight, and "until quiet" is the honest
/// definition of converged.
Future<void> converge(Device a, Device b) async {
  for (var round = 0; round < 3; round++) {
    await a.pushTo(b);
    await b.pushTo(a);
    if (a.sender.selectDelta(b.deviceId).publications.isEmpty &&
        a.sender.selectDelta(b.deviceId).deletes.isEmpty &&
        b.sender.selectDelta(a.deviceId).publications.isEmpty &&
        b.sender.selectDelta(a.deviceId).deletes.isEmpty) {
      return;
    }
  }
}

/// One device: a store, its two sync entry points, and the handful of user-level
/// operations the scenarios need.
class Device {
  Device(this.tag, this.deviceId, {String model = testModel})
      : store = openTestStore(tag),
        model = model {
    library = ObjectBoxLibraryRepository(store);
    tombstones = TombstoneStore(store);
    applier = SyncApplier(
      store: store,
      activeEmbeddingModelId: model,
      deviceId: deviceId,
      tombstones: tombstones,
    );
    sender = PushSender(store: store, deviceId: deviceId, tombstones: tombstones);
  }

  final String tag;
  final String deviceId;
  final Store store;
  final String model;

  late final ObjectBoxLibraryRepository library;
  late final TombstoneStore tombstones;
  late final SyncApplier applier;
  late final PushSender sender;

  /// A push over the link. [deliver] throwing models an interrupted transfer,
  /// which is how the watermark's ack-after-send rule is exercised.
  Future<void> pushTo(Device peer) =>
      sender.push(peer.deviceId, (encoded) async => peer.applier.ingestEncoded(encoded));

  String createNotebook(String title) {
    final notebook = ObNotebook(
      uuid: newUuidV7(),
      title: title,
      createdAt: DateTime.now().toUtc(),
    );
    store.box<ObNotebook>().put(notebook);
    return notebook.uuid;
  }

  String createPublication({
    required String title,
    required String body,
    int chunkCount = 3,
    String? notebook,
  }) {
    final created = library.create(
      title: title,
      sourceMarkdown: body,
      embeddingModelId: model,
    );
    if (chunkCount > 0) {
      library.replaceChunks(created.uuid, [
        for (var i = 0; i < chunkCount; i++) localDraft(title, i),
      ]);
    }
    if (notebook != null) library.attach(created.uuid, notebook);
    return created.uuid;
  }

  /// A rename, which the data layer has no operation for — see the push test for
  /// why. Metadata version only; that is the whole point.
  void rename(String uuid, String title) {
    final box = store.box<ObPublication>();
    final row = box.query(ObPublication_.uuid.equals(uuid)).build().findFirst()!;
    row.title = title;
    row.versionCounter++;
    box.put(row);
  }

  void reindex(String uuid, int chunkCount) {
    library.replaceChunks(uuid, [
      for (var i = 0; i < chunkCount; i++) localDraft('reindexed', i, seed: 40),
    ]);
  }

  void attach(String uuid, String notebookUuid) =>
      library.attach(uuid, notebookUuid);

  /// The local delete path, which cascades *and* stamps a tombstone with a
  /// version so the delete can be selected into a later push.
  void delete(String uuid) => applier.deleteLocally(uuid);

  /// Deletes a notebook locally: the notebook and its exclusive publications,
  /// each tombstoned, in one transaction.
  void deleteNotebook(String uuid) =>
      SyncDeleter(store: store, deviceId: deviceId, tombstones: tombstones)
          .deleteNotebookLocally(uuid);

  /// Applies a payload built in the test rather than selected from this device.
  void ingestDirect(PublicationDto dto) => applier.ingest(SyncPayload(
        publications: [dto],
        deletes: const [],
      ));

  ObPublication read(String uuid) => readOrNull(uuid)!;

  ObPublication? readOrNull(String uuid) =>
      store.box<ObPublication>().query(ObPublication_.uuid.equals(uuid)).build()
          .findFirst();

  String? documentOf(String uuid) {
    final publication = readOrNull(uuid);
    if (publication == null) return null;
    final row = store
        .box<ObDocument>()
        .query(ObDocument_.uuid.equals(documentUuidFor(uuid)))
        .build()
        .findFirst();
    return row?.markdown;
  }

  List<ObChunk> chunksOf(String uuid) {
    final publication = readOrNull(uuid);
    if (publication == null) return const [];
    return store
        .box<ObChunk>()
        .query(ObChunk_.publicationId.equals(publication.id))
        .build()
        .find();
  }

  void dispose() => store.close();
}

/// Encodes [payload] in a fresh isolate and returns the result.
Future<String> _encodeInIsolate(SyncPayload payload) async {
  final result = ReceivePort();
  try {
    await Isolate.spawn(
      _encodeEntryPoint,
      [payload, result.sendPort],
      errorsAreFatal: true,
    );
    return await result.first as String;
  } finally {
    result.close();
  }
}

/// Top level, because an isolate entry point must be.
void _encodeEntryPoint(List<Object?> arguments) {
  final payload = arguments[0] as SyncPayload;
  final port = arguments[1] as SendPort;
  port.send(encodePayload(payload));
}

/// A deterministic chunk draft, so a seeded corpus is reproducible.
ChunkDraft localDraft(String prefix, int index, {int seed = 0}) => ChunkDraft(
      chunkIndex: index,
      content: '$prefix chunk $index',
      tokenCount: 4,
      embedding: unitVector(seed + index),
    );

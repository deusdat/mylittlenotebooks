import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/data/identity.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_note.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_note_chunk.dart';
import 'package:mylittlenotebooks/data/objectbox/objectbox_store.dart';
import 'package:mylittlenotebooks/data/objectbox_note_repository.dart';
import 'package:mylittlenotebooks/data/objectbox_notebook_repository.dart';
import 'package:mylittlenotebooks/data/sync/push_sender.dart';
import 'package:mylittlenotebooks/data/sync/sync_apply.dart';
import 'package:mylittlenotebooks/data/sync/sync_deleter.dart';
import 'package:mylittlenotebooks/data/sync/sync_payload.dart';
import 'package:mylittlenotebooks/data/sync/sync_tombstones.dart';
import 'package:mylittlenotebooks/data/sync/sync_validator.dart';
import 'package:mylittlenotebooks/models/chunk.dart';
import 'package:mylittlenotebooks/objectbox.g.dart';

import 'sync_test_fixtures.dart';

void main() {
  late _Device laptop;
  late _Device phone;

  setUp(() {
    laptop = _Device('note-laptop', 'd-laptop');
    phone = _Device('note-phone', 'd-phone');
  });

  tearDown(() {
    laptop.dispose();
    phone.dispose();
  });

  group('note payload round-trip (AC16)', () {
    test('a note with a body and chunks converges', () async {
      final uuid = laptop.createNote(body: '# Title\n\nhello', chunkCount: 3);

      await laptop.pushTo(phone);

      final read = phone.notes.byUuid(uuid)!;
      expect(read.body, '# Title\n\nhello');
      expect(read.chunkCount, 3);
      expect(read.embeddingModelId, testModel);
      expect(phone.noteChunks(uuid), hasLength(3));
    });

    test('a malformed note record refuses the whole payload', () {
      final payload = SyncPayload(publications: const [], deletes: const [], notes: [
        NoteDto(
          uuid: 'n-1',
          title: 'x',
          createdAt: DateTime.now().toUtc(),
          updatedAt: DateTime.now().toUtc(),
          embeddingModelId: testModel,
          // declares 2 but carries 0 chunks -> inconsistent
          declaredChunkCount: 2,
          version: const VersionDto(counter: 1, deviceId: 'd'),
          chunkSetVersion: const VersionDto(counter: 1, deviceId: 'd'),
          chunksIncluded: true,
          notebookUuids: const [],
        ),
      ]);
      expect(
        () => phone.applier.ingest(payload),
        throwsA(isA<ChunkSetRejection>()),
      );
    });
  });

  group('metadata-only push (AC17, AC20)', () {
    test('a retitle sends metadata and no chunk set', () async {
      final uuid = laptop.createNote(body: 'body', chunkCount: 2);
      await laptop.pushTo(phone);

      laptop.notes.updateMetadata(uuid, title: 'Renamed');

      final delta = laptop.sender.selectDelta(phone.deviceId);
      final dto = delta.notes.single;
      expect(dto.chunksIncluded, isFalse);
      expect(dto.chunks, isEmpty);
      expect(dto.document, isNull,
          reason: 'a title change must not ship the body');

      await laptop.pushTo(phone);
      expect(phone.notes.byUuid(uuid)!.title, 'Renamed');
      expect(phone.noteChunks(uuid), hasLength(2),
          reason: 'the receiver keeps its chunks');
    });

    test('a body re-index sends the body and the set', () async {
      final uuid = laptop.createNote(body: 'v1', chunkCount: 2);
      await laptop.pushTo(phone);

      laptop.notes.replaceBodyAndChunks(
        uuid,
        title: null,
        body: 'v2',
        embeddingModelId: testModel,
        chunks: [draftFor(0, seed: 7)],
      );

      final delta = laptop.sender.selectDelta(phone.deviceId);
      final dto = delta.notes.single;
      expect(dto.chunksIncluded, isTrue);
      expect(dto.chunks, hasLength(1));
      expect(dto.document, isNotNull);

      await laptop.pushTo(phone);
      expect(phone.notes.byUuid(uuid)!.body, 'v2');
      expect(phone.noteChunks(uuid), hasLength(1));
    });
  });

  group('model gate (AC18)', () {
    test('a mismatched model withholds vectors but transfers the body', () async {
      final uuid = laptop.createNote(
        body: 'peer body',
        chunkCount: 2,
        model: 'other-model:int8:256',
      );

      await laptop.pushTo(phone);

      final read = phone.notes.byUuid(uuid)!;
      expect(read.body, 'peer body');
      expect(read.chunkCount, 0,
          reason: 'the receiver must hold exactly 0 vectors');
      expect(phone.noteChunks(uuid), isEmpty);
      final row = phone.noteRow(uuid);
      expect(row.chunkSetVersion, 0,
          reason: 'the refused set stays pending, not advanced');
      expect(row.embeddingState, 'inProcess',
          reason: 'a gated note must be re-embedded locally (FR11a)');
    });
  });

  group('deletes (AC19)', () {
    test('a delete beats an upsert for the same uuid', () async {
      final uuid = laptop.createNote(body: 'body', chunkCount: 1);
      await laptop.pushTo(phone);

      // Laptop deletes and tombstone-travels; the phone applies it.
      laptop.deleter.deleteNoteLocally(uuid);
      await laptop.pushTo(phone);

      expect(phone.notes.byUuid(uuid), isNull);

      // A late in-flight upsert cannot resurrect it.
      final stale = SyncPayload(
        publications: const [],
        deletes: const [],
        notes: [
          NoteDto(
            uuid: uuid,
            title: 'zombie',
            createdAt: DateTime.now().toUtc(),
            updatedAt: DateTime.now().toUtc(),
            embeddingModelId: testModel,
            declaredChunkCount: 0,
            version: const VersionDto(counter: 999, deviceId: 'd-laptop'),
            chunkSetVersion: const VersionDto(counter: 1, deviceId: 'd-laptop'),
            chunksIncluded: false,
            notebookUuids: const [],
          ),
        ],
      );
      phone.applier.ingest(stale);
      expect(phone.notes.byUuid(uuid), isNull);
    });
  });

  group('identity (AC22)', () {
    test('derived note identifiers are valid', () {
      final noteUuid = newUuidV7();
      expect(isValidIdentifier(noteChunkUuidFor(noteUuid, 3)), isTrue);
      expect(isValidIdentifier(noteDocumentUuidFor(noteUuid)), isTrue);
      expect(parentNoteUuidOf(noteChunkUuidFor(noteUuid, 3)), noteUuid);
      expect(parentNoteUuidOf(noteDocumentUuidFor(noteUuid)), noteUuid);
      // The publication forms still work.
      expect(isValidIdentifier(chunkUuidFor(noteUuid, 0)), isTrue);
      expect(isValidIdentifier(documentUuidFor(noteUuid)), isTrue);
      expect(isValidIdentifier('not-an-id'), isFalse);
    });
  });
}

class _Device {
  _Device(this.tag, this.deviceId) : store = openTestStore(tag);

  final String tag;
  final String deviceId;
  final Store store;

  late final ObjectBoxNotebookRepository notebooks =
      ObjectBoxNotebookRepository(store);
  late final ObjectBoxNoteRepository notes =
      ObjectBoxNoteRepository(store);
  late final TombstoneStore tombstones = TombstoneStore(store);
  late final SyncDeleter deleter = SyncDeleter(
      store: store, deviceId: deviceId, tombstones: tombstones);
  late final SyncApplier applier = SyncApplier(
    store: store,
    activeEmbeddingModelId: testModel,
    deviceId: deviceId,
    tombstones: tombstones,
  );
  late final PushSender sender =
      PushSender(store: store, deviceId: deviceId, tombstones: tombstones);

  Future<void> pushTo(_Device peer) => sender.push(
      peer.deviceId, (encoded) async => peer.applier.ingestEncoded(encoded));

  String createNote({
    required String body,
    int chunkCount = 3,
    String model = testModel,
  }) {
    final notebook = notebooks.create();
    final note = notes.create(title: 'Note', notebookUuid: notebook.id);
    if (body.isEmpty) return note.uuid;
    notes.replaceBodyAndChunks(
      note.uuid,
      title: 'Note',
      body: body,
      embeddingModelId: model,
      chunks: [for (var i = 0; i < chunkCount; i++) draftFor(i, seed: i)],
    );
    return note.uuid;
  }

  List<ObNoteChunk> noteChunks(String uuid) {
    final row = noteRow(uuid);
    return store
        .box<ObNoteChunk>()
        .query(ObNoteChunk_.noteId.equals(row.id))
        .build()
        .find();
  }

  ObNote noteRow(String uuid) => store
      .box<ObNote>()
      .query(ObNote_.uuid.equals(uuid))
      .build()
      .findFirst()!;

  void dispose() => store.close();
}

ChunkDraft draftFor(int index, {int seed = 0}) => ChunkDraft(
      chunkIndex: index,
      content: 'chunk $index',
      tokenCount: 3,
      embedding: unitVector(seed),
    );

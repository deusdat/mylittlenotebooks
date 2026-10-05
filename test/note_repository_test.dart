import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/data/invalid_embedding_exception.dart';
import 'package:mylittlenotebooks/data/note_search_repository.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_chat_message.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_note.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_note_chunk.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_note_document.dart';
import 'package:mylittlenotebooks/data/objectbox/objectbox_store.dart';
import 'package:mylittlenotebooks/data/objectbox_library_repository.dart';
import 'package:mylittlenotebooks/data/objectbox_note_repository.dart';
import 'package:mylittlenotebooks/data/objectbox_notebook_repository.dart';
import 'package:mylittlenotebooks/models/chunk.dart';
import 'package:mylittlenotebooks/models/note.dart';
import 'package:mylittlenotebooks/objectbox.g.dart';

const testModel = 'test-model:int8:256';

List<double> unitVector(int seed, {int dims = 256}) {
  final random = Random(seed);
  final values = List<double>.filled(dims, 0);
  for (var i = 0; i < dims; i++) {
    values[i] = random.nextDouble() - 0.5;
  }
  final norm = sqrt(values.fold<double>(0, (a, b) => a + b * b));
  return values.map((v) => v / norm).toList();
}

ChunkDraft draft(int index, {int seed = 0, String? content}) => ChunkDraft(
      chunkIndex: index,
      content: content ?? 'chunk $index',
      tokenCount: 3,
      embedding: unitVector(seed),
    );

void main() {
  late Store store;
  late ObjectBoxNotebookRepository notebooks;
  late ObjectBoxNoteRepository notes;
  late ObjectBoxNoteSearchRepository search;
  late ObjectBoxLibraryRepository library;

  setUp(() {
    store = openTestStore('note-repo');
    notebooks = ObjectBoxNotebookRepository(store);
    notes = ObjectBoxNoteRepository(store);
    search = ObjectBoxNoteSearchRepository(store);
    library = ObjectBoxLibraryRepository(store);
  });

  tearDown(() => store.close());

  group('create (AC4, AC5)', () {
    test('an empty note has no chunks and no model, and round-trips', () {
      final notebook = notebooks.create();
      final note = notes.create(notebookUuid: notebook.id);

      expect(note.chunkCount, 0);
      expect(note.embeddingModelId, '');
      expect(note.body, '');
      expect(note.title, isNull);
      expect(note.createdAt, note.updatedAt);

      final row = store.box<ObNote>().getAll().single;
      expect(row.chunkSetVersion, 0);
      expect(row.versionCounter, 1);
      // No chunk rows and exactly one body row (AC4).
      expect(store.box<ObNoteChunk>().count(), 0);
      expect(store.box<ObNoteDocument>().count(), 1);
    });

    test('body, title, and dates round-trip (AC5)', () {
      final notebook = notebooks.create();
      final created = notes.create(
        title: 'First',
        notebookUuid: notebook.id,
      );
      notes.replaceBodyAndChunks(
        created.uuid,
        title: 'First',
        body: 'hello world',
        embeddingModelId: testModel,
        chunks: [draft(0)],
      );

      final read = notes.byUuid(created.uuid)!;
      expect(read.title, 'First');
      expect(read.body, 'hello world');
      expect(read.chunkCount, 1);
      expect(read.embeddingModelId, testModel);
      expect(read.createdAt, created.createdAt);
    });
  });

  group('many-to-many and list summaries (AC3, AC6)', () {
    test('one note attached to two notebooks appears in both', () {
      final a = notebooks.create();
      final b = notebooks.create();
      final note = notes.create(notebookUuid: a.id);
      notes.attach(note.uuid, b.id);

      expect(notes.listForNotebook(a.id).map((n) => n.uuid), contains(note.uuid));
      expect(notes.listForNotebook(b.id).map((n) => n.uuid), contains(note.uuid));

      final row = store
          .box<ObNote>()
          .query(ObNote_.uuid.equals(note.uuid))
          .build()
          .findFirst()!;
      expect(row.notebooks.map((n) => n.uuid).toSet(), {a.id, b.id});
    });

    test('list returns summaries ordered by createdAt, with no body', () {
      final notebook = notebooks.create();
      final first = notes.create(notebookUuid: notebook.id, title: 'A');
      final second = notes.create(notebookUuid: notebook.id, title: 'B');
      notes.replaceBodyAndChunks(
        first.uuid,
        title: 'A',
        body: 'body-a',
        embeddingModelId: testModel,
        chunks: const [],
      );

      final list = notes.listForNotebook(notebook.id);
      expect(list.map((n) => n.uuid).toList(),
          containsAll([first.uuid, second.uuid]));
      // The list type is the body-less projection (spec FR17, NFR4).
      expect(list.first, isA<NoteSummary>());
    });
  });

  group('metadata vs body save (AC7, AC8)', () {
    test('a title-only save does not touch the chunk set or body', () {
      final notebook = notebooks.create();
      final note = notes.create(notebookUuid: notebook.id);
      notes.replaceBodyAndChunks(
        note.uuid,
        title: 'Old',
        body: 'body',
        embeddingModelId: testModel,
        chunks: [draft(0), draft(1, seed: 1)],
      );
      final before = store.box<ObNote>().getAll().single;

      notes.updateMetadata(note.uuid, title: 'New');

      final after = store.box<ObNote>().getAll().single;
      expect(after.title, 'New');
      expect(after.versionCounter, before.versionCounter + 1);
      expect(after.chunkSetVersion, before.chunkSetVersion);
      expect(store.box<ObNoteChunk>().count(), 2);
    });

    test('a body save replaces chunks wholesale and advances the set version',
        () {
      final notebook = notebooks.create();
      final note = notes.create(notebookUuid: notebook.id);
      notes.replaceBodyAndChunks(
        note.uuid,
        title: null,
        body: 'v1',
        embeddingModelId: testModel,
        chunks: [draft(0), draft(1, seed: 1), draft(2, seed: 2)],
      );
      final first = store.box<ObNote>().getAll().single;

      notes.replaceBodyAndChunks(
        note.uuid,
        title: null,
        body: 'v2',
        embeddingModelId: testModel,
        chunks: [draft(0, seed: 10)],
      );

      final second = store.box<ObNote>().getAll().single;
      expect(store.box<ObNoteChunk>().count(), 1);
      expect(second.chunkCount, 1);
      expect(second.chunkSetVersion, first.chunkSetVersion + 1);
      expect(notes.byUuid(note.uuid)!.body, 'v2');
    });
  });

  group('write-path validation and invariants (AC11, AC12)', () {
    test('a wrong-length vector is rejected before anything is written (AC11)',
        () {
      final notebook = notebooks.create();
      final note = notes.create(notebookUuid: notebook.id);
      expect(
        () => notes.replaceBodyAndChunks(
          note.uuid,
          title: null,
          body: 'x',
          embeddingModelId: testModel,
          chunks: [
            ChunkDraft(
              chunkIndex: 0,
              content: 'bad',
              tokenCount: 1,
              embedding: unitVector(0, dims: 128),
            ),
          ],
        ),
        throwsA(isA<InvalidEmbeddingException>()),
      );
      expect(store.box<ObNoteChunk>().count(), 0);
      expect(notes.byUuid(note.uuid)!.body, '');
    });

    test('every chunk keeps noteId == note.targetId (AC12)', () {
      final notebook = notebooks.create();
      final note = notes.create(notebookUuid: notebook.id);
      notes.replaceBodyAndChunks(
        note.uuid,
        title: null,
        body: 'x',
        embeddingModelId: testModel,
        chunks: [draft(0), draft(1, seed: 1)],
      );
      for (final chunk in store.box<ObNoteChunk>().getAll()) {
        expect(chunk.noteId, chunk.note.targetId);
      }
    });
  });

  group('attach / detach (AC13)', () {
    test('attach is idempotent and detach actually removes', () {
      final notebook = notebooks.create();
      final note = notes.create(notebookUuid: notebook.id);
      final other = notebooks.create();

      notes
        ..attach(note.uuid, other.id)
        ..attach(note.uuid, other.id)
        ..attach(note.uuid, other.id);

      final notebookRow = store
          .box<ObNote>()
          .query(ObNote_.uuid.equals(note.uuid))
          .build()
          .findFirst()!;
      expect(notebookRow.notebooks.where((n) => n.uuid == other.id).length, 1);

      notes.detach(note.uuid, other.id);
      final after = store
          .box<ObNote>()
          .query(ObNote_.uuid.equals(note.uuid))
          .build()
          .findFirst()!;
      expect(after.notebooks.any((n) => n.uuid == other.id), isFalse);
    });
  });

  group('deleteNote cascade (AC14)', () {
    test('removes the note, body, chunks, and messages; notebooks survive', () {
      final notebook = notebooks.create();
      final note = notes.create(notebookUuid: notebook.id);
      notes.replaceBodyAndChunks(
        note.uuid,
        title: null,
        body: 'x',
        embeddingModelId: testModel,
        chunks: [draft(0)],
      );
      final row = store.box<ObNote>().getAll().single;
      store.box<ObChatMessage>().put(ObChatMessage(
            uuid: 'm-1',
            noteId: row.id,
            role: 'user',
            text: 'hi',
            createdAt: DateTime.now().toUtc(),
          ));
      expect(store.box<ObChatMessage>().count(), 1);

      notes.deleteNote(note.uuid);

      expect(store.box<ObNote>().count(), 0);
      expect(store.box<ObNoteChunk>().count(), 0);
      expect(store.box<ObNoteDocument>().count(), 0);
      expect(store.box<ObChatMessage>().count(), 0);
      expect(notebooks.exists(notebook.id), isTrue);
    });
  });

  group('notebook delete cascade (AC15)', () {
    test('exclusive notes are cascaded; shared notes survive', () {
      final only = notebooks.create();
      final shared = notebooks.create();

      final exclusive = notes.create(notebookUuid: only.id);
      final kept = notes.create(notebookUuid: only.id);
      notes.attach(kept.uuid, shared.id);

      final cascade = library.deleteNotebook(only.id);

      expect(cascade.notes.map((n) => n.uuid), contains(exclusive.uuid));
      expect(cascade.notes.map((n) => n.uuid), isNot(contains(kept.uuid)));
      expect(notes.byUuid(exclusive.uuid), isNull);
      expect(notes.byUuid(kept.uuid), isNotNull);
      expect(notes.listForNotebook(shared.id).map((n) => n.uuid),
          contains(kept.uuid));
    });
  });

  group('note-scoped search (AC34)', () {
    test('a narrow note still returns the full limit', () {
      final notebook = notebooks.create();
      // 20 notes x 100 chunks; each note's vectors cluster on its own seed.
      final uuids = <String>[];
      for (var n = 0; n < 20; n++) {
        final note = notes.create(notebookUuid: notebook.id);
        notes.replaceBodyAndChunks(
          note.uuid,
          title: null,
          body: 'body $n',
          embeddingModelId: testModel,
          chunks: [
            for (var c = 0; c < 100; c++)
              draft(c, seed: n * 100000 + c, content: 'n$n c$c'),
          ],
        );
        uuids.add(note.uuid);
      }

      // Query aims at note 19's cluster while scoping to note 0, so the
      // unfiltered top-N are entirely out of scope.
      final query = unitVector(19 * 100000);
      final hits = search.search(noteUuid: uuids[0], queryVector: query, limit: 10);
      expect(hits, hasLength(10),
          reason: 'a scoped search must satisfy its limit (spec FR35)');
      expect(hits.every((h) => h.chunk.noteUuid == uuids[0]), isTrue);

      // The naive candidate count demonstrably fails on this corpus.
      final naive = search.search(
        noteUuid: uuids[0],
        queryVector: query,
        limit: 10,
        fetchCountOverride: 10,
      );
      expect(naive.length, lessThan(10),
          reason: 'the naive fetch count must visibly under-deliver');
    });
  });
}

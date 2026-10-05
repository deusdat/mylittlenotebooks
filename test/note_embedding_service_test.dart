import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/data/embedding/embedder.dart';
import 'package:mylittlenotebooks/data/embedding/note_embedding_service.dart';
import 'package:mylittlenotebooks/data/embedding/note_indexer.dart';
import 'package:mylittlenotebooks/data/embedding/text_chunker.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_note.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_note_chunk.dart';
import 'package:mylittlenotebooks/data/objectbox/objectbox_store.dart';
import 'package:mylittlenotebooks/data/objectbox_note_repository.dart';
import 'package:mylittlenotebooks/data/objectbox_notebook_repository.dart';
import 'package:mylittlenotebooks/models/note.dart';
import 'package:mylittlenotebooks/objectbox.g.dart';

/// Boot recovery (spec FR11a): a note left in-process by an interrupted save is
/// re-embedded at the next launch.
void main() {
  late Store store;
  late ObjectBoxNoteRepository notes;
  late DeterministicEmbedder embedder;
  late NoteEmbeddingService service;

  setUp(() {
    store = openTestStore('recovery');
    notes = ObjectBoxNoteRepository(store);
    embedder = DeterministicEmbedder();
    service = NoteEmbeddingService(
      repo: notes,
      indexer: NoteIndexer(
        chunker: HeadingAwareTextChunker(tokenizer: WhitespaceTokenizer()),
        embedder: embedder,
      ),
    );
  });

  tearDown(() => store.close());

  test('an interrupted save is re-embedded and marked complete', () async {
    final notebook = ObjectBoxNotebookRepository(store).create();
    final note = notes.create(notebookUuid: notebook.id);

    // The durable "begin" from a save that never completed.
    notes.beginEmbedding(note.uuid, title: 'T', body: 'hello world');
    expect(store.box<ObNote>().getAll().single.embeddingState, 'inProcess');
    expect(store.box<ObNoteChunk>().count(), 0);

    await service.recoverAll();
    await service.idle;

    final row = store.box<ObNote>().getAll().single;
    expect(row.embeddingState, 'complete');
    expect(row.chunkCount, greaterThan(0));
    expect(store.box<ObNoteChunk>().count(), row.chunkCount);
    expect(notes.byUuid(note.uuid)!.embeddingState, NoteEmbeddingState.complete);
  });

  test('a completed note is left alone', () async {
    final notebook = ObjectBoxNotebookRepository(store).create();
    final note = notes.create(notebookUuid: notebook.id);
    final other = notes.create(notebookUuid: notebook.id);
    notes.completeEmbedding(other.uuid,
        embeddingModelId: 'deterministic:int8:256', chunks: const []);

    expect(notes.inProcessNoteUuids(), isEmpty);

    await service.recoverAll();
    await service.idle;

    expect(embedder.received, isEmpty);
    expect(notes.byUuid(note.uuid)!.embeddingState, NoteEmbeddingState.complete);
  });
}

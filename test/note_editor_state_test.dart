import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/data/embedding/embedder.dart';
import 'package:mylittlenotebooks/data/embedding/note_embedding_service.dart';
import 'package:mylittlenotebooks/data/embedding/note_indexer.dart';
import 'package:mylittlenotebooks/data/embedding/text_chunker.dart';
import 'package:mylittlenotebooks/data/in_memory_note_repository.dart';
import 'package:mylittlenotebooks/models/note.dart';
import 'package:mylittlenotebooks/state/note_editor_state.dart';
import 'package:mylittlenotebooks/state/use_note_editor.dart';
import 'package:utopia_hooks/utopia_hooks.dart';

/// Save semantics (spec FR11, FR11a, FR29, FR30), exercised with no widget tree.
void main() {
  late InMemoryNoteRepository repo;
  late DeterministicEmbedder embedder;
  late NoteIndexer indexer;
  late NoteEmbeddingService embedding;

  const model = 'deterministic:int8:256';

  setUp(() {
    repo = InMemoryNoteRepository();
    embedder = DeterministicEmbedder();
    indexer = NoteIndexer(
      chunker: HeadingAwareTextChunker(tokenizer: WhitespaceTokenizer()),
      embedder: embedder,
    );
    embedding = NoteEmbeddingService(repo: repo, indexer: indexer);
  });

  Note seed({String body = 'original body'}) {
    final note = repo.create(title: 'Title', notebookUuid: 'nb-1');
    repo.replaceBodyAndChunks(
      note.uuid,
      title: 'Title',
      body: body,
      embeddingModelId: model,
      chunks: const [],
    );
    return repo.byUuid(note.uuid)!;
  }

  SimpleHookContext<NoteEditorState> contextFor(Note? note, {
    void Function(String uuid)? onSaved,
  }) {
    final ctx = SimpleHookContext(() => useNoteEditor(
          note: note,
          notebookId: 'nb-1',
          repo: repo,
          embedding: embedding,
          activeModelId: model,
          onSaved: onSaved,
        ));
    addTearDown(ctx.dispose);
    return ctx;
  }

  test('a body change is durable and re-embeds in the background (FR11a)',
      () async {
    final note = seed();
    final ctx = contextFor(note);

    ctx.value.setBody('new body');
    ctx.rebuild();
    expect(ctx.value.dirty, isTrue);

    await ctx.value.save();
    // The body is durable immediately, before the embedding finishes.
    expect(repo.byUuid(note.uuid)!.body, 'new body');

    await embedding.idle;
    ctx.rebuild();

    expect(ctx.value.dirty, isFalse);
    expect(embedder.received, contains('search_document: new body'));
    expect(repo.byUuid(note.uuid)!.embeddingState, NoteEmbeddingState.complete);
  });

  test('a title-only save never calls the embedder (FR11)', () async {
    final note = seed();
    final ctx = contextFor(note);

    ctx.value.setTitle('Renamed');
    ctx.rebuild();
    await ctx.value.save();
    await embedding.idle;
    ctx.rebuild();

    expect(embedder.received, isEmpty);
    expect(repo.byUuid(note.uuid)!.title, 'Renamed');
    expect(repo.byUuid(note.uuid)!.embeddingState, NoteEmbeddingState.complete);
  });

  test('an unchanged note writes nothing (FR11)', () async {
    final note = seed();
    final ctx = contextFor(note);

    expect(ctx.value.dirty, isFalse);
    await ctx.value.save();
    await embedding.idle;
    ctx.rebuild();

    expect(embedder.received, isEmpty);
    expect(repo.byUuid(note.uuid)!.updatedAt, note.updatedAt);
  });

  test('cancel restores the last saved values and clears dirty', () async {
    final note = seed();
    final ctx = contextFor(note);

    ctx.value.setBody('unsaved');
    ctx.value.setTitle('Unsaved title');
    ctx.rebuild();
    expect(ctx.value.dirty, isTrue);

    ctx.value.cancel();
    ctx.rebuild();

    expect(ctx.value.dirty, isFalse);
    expect(ctx.value.body, 'original body');
    expect(ctx.value.title, 'Title');
    expect(repo.byUuid(note.uuid)!.body, 'original body');
  });

  test('saving a new note creates it and embeds the body (FR30)', () async {
    String? created;
    final ctx = contextFor(null, onSaved: (uuid) => created = uuid);

    ctx.value.setTitle('Fresh');
    ctx.value.setBody('hello world');
    ctx.rebuild();
    await ctx.value.save();
    await embedding.idle;
    ctx.rebuild();

    expect(created, isNotNull);
    expect(repo.byUuid(created!)!.body, 'hello world');
    expect(repo.byUuid(created!)!.embeddingState, NoteEmbeddingState.complete);
  });

  test('an in-process note is flagged for the banner (FR36)', () async {
    final note = repo.create(notebookUuid: 'nb-1');
    repo.beginEmbedding(note.uuid, title: null, body: 'has a body');
    final reloaded = repo.byUuid(note.uuid)!;
    expect(reloaded.embeddingState, NoteEmbeddingState.inProcess);
    final ctx = contextFor(reloaded);
    expect(ctx.value.isUnindexed, isTrue);
  });
}

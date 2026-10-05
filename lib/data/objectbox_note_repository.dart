import 'package:mylittlenotebooks/data/embedding_validation.dart';
import 'package:mylittlenotebooks/data/identity.dart';
import 'package:mylittlenotebooks/data/note_repository.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_chat_message.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_note.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_note_chunk.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_note_document.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_notebook.dart';
import 'package:mylittlenotebooks/domain_mapping.dart';
import 'package:mylittlenotebooks/models/chunk.dart';
import 'package:mylittlenotebooks/models/note.dart';
import 'package:mylittlenotebooks/objectbox.g.dart';

/// ObjectBox-backed [NoteRepository] (spec FR10–FR17).
///
/// The transaction rule this class enforces: a body save writes the body, the
/// chunk set, the counts, and all three versions in **one**
/// `runInTransaction(TxMode.write, …)`, so a note is never observable with a new
/// body and the old chunk set (spec FR12).
class ObjectBoxNoteRepository implements NoteRepository {
  ObjectBoxNoteRepository(this._store)
      : _notes = _store.box<ObNote>(),
        _documents = _store.box<ObNoteDocument>(),
        _chunks = _store.box<ObNoteChunk>(),
        _notebooks = _store.box<ObNotebook>();

  final Store _store;
  final Box<ObNote> _notes;
  final Box<ObNoteDocument> _documents;
  final Box<ObNoteChunk> _chunks;
  final Box<ObNotebook> _notebooks;

  /// Exposed so sibling repositories share one connection (ObjectBox permits
  /// exactly one open store per directory).
  Store get store => _store;

  @override
  Note create({
    String? title,
    required String notebookUuid,
    String embeddingModelId = '',
  }) {
    final notebook = _requireNotebook(notebookUuid);

    late final ObNote note;
    _store.runInTransaction(TxMode.write, () {
      final now = _nowUtc();
      // `embeddingModelId` starts empty: creation does not embed, because an
      // empty body has no chunks (spec FR9, FR10).
      note = ObNote(
        uuid: newUuidV7(),
        title: title,
        createdAt: now,
        updatedAt: now,
        embeddingModelId: '',
        // A creation is a modification, so the record starts at 1.
        versionCounter: 1,
      );
      _notes.put(note);

      final document = ObNoteDocument(
        uuid: noteDocumentUuidFor(note.uuid),
        noteId: note.id,
        markdown: '',
        versionCounter: 1,
      );
      document.note.targetId = note.id;
      _documents.put(document);

      notebook.notes.add(note);
      _notebooks.put(notebook);
    });

    return note.toDomain(body: '');
  }

  @override
  void updateMetadata(String noteUuid, {required String? title}) {
    _store.runInTransaction(TxMode.write, () {
      final note = _requireNote(noteUuid);
      note.title = title;
      note.updatedAt = _nowUtc();
      note.versionCounter++;
      _notes.put(note);
    });
  }

  @override
  void beginEmbedding(
    String noteUuid, {
    required String? title,
    required String body,
  }) {
    _store.runInTransaction(TxMode.write, () {
      final note = _requireNote(noteUuid);

      final document = _requireDocument(note.id);
      document.markdown = body;
      document.versionCounter++;
      _documents.put(document);

      // Drop the stale set so a changed body is never half-searchable while the
      // new embeddings are built (spec FR11a).
      _removeChunksFor(note.id);

      note.title = title;
      note.chunkCount = 0;
      note.embeddingState = NoteEmbeddingState.inProcess.storage;
      note.versionCounter++;
      note.updatedAt = _nowUtc();
      _notes.put(note);
    });
  }

  @override
  void completeEmbedding(
    String noteUuid, {
    required String embeddingModelId,
    required List<ChunkDraft> chunks,
  }) {
    for (final draft in chunks) {
      validateEmbedding(draft.embedding);
    }

    _store.runInTransaction(TxMode.write, () {
      final note = _requireNote(noteUuid);
      _removeChunksFor(note.id);
      final entities = chunks
          .map((d) => d.toNoteChunkEntity(noteId: note.id, noteUuid: note.uuid))
          .toList();
      _chunks.putMany(entities);

      note.chunkCount = entities.length;
      note.chunkSetVersion++;
      note.versionCounter++;
      note.embeddingModelId = embeddingModelId;
      note.embeddingState = NoteEmbeddingState.complete.storage;
      note.updatedAt = _nowUtc();
      _notes.put(note);
    });
  }

  @override
  void replaceBodyAndChunks(
    String noteUuid, {
    required String? title,
    required String body,
    required String embeddingModelId,
    required List<ChunkDraft> chunks,
  }) {
    // Validate every draft BEFORE opening the transaction, so a bad vector can
    // never leave a partial write behind (spec FR8, FR12).
    for (final draft in chunks) {
      validateEmbedding(draft.embedding);
    }

    _store.runInTransaction(TxMode.write, () {
      final note = _requireNote(noteUuid);
      note.title = title;
      note.embeddingModelId = embeddingModelId;
      note.embeddingState = NoteEmbeddingState.complete.storage;

      final document = _requireDocument(note.id);
      document.markdown = body;
      document.versionCounter++;
      _documents.put(document);

      _removeChunksFor(note.id);
      final entities = chunks
          .map((d) => d.toNoteChunkEntity(noteId: note.id, noteUuid: note.uuid))
          .toList();
      _chunks.putMany(entities);

      note.chunkCount = entities.length;
      note.chunkSetVersion++;
      note.versionCounter++;
      note.updatedAt = _nowUtc();
      _notes.put(note);
    });
  }

  @override
  void replaceChunks(String noteUuid, List<ChunkDraft> chunks) {
    for (final draft in chunks) {
      validateEmbedding(draft.embedding);
    }

    _store.runInTransaction(TxMode.write, () {
      final note = _requireNote(noteUuid);
      _removeChunksFor(note.id);
      final entities = chunks
          .map((d) => d.toNoteChunkEntity(noteId: note.id, noteUuid: note.uuid))
          .toList();
      _chunks.putMany(entities);

      note.chunkCount = entities.length;
      note.chunkSetVersion++;
      note.versionCounter++;
      // A full chunk set from the sync path means the note holds vectors.
      note.embeddingState = NoteEmbeddingState.complete.storage;
      note.updatedAt = _nowUtc();
      _notes.put(note);
    });
  }

  @override
  void attach(String noteUuid, String notebookUuid) {
    final note = _requireNote(noteUuid);
    final notebook = _requireNotebook(notebookUuid);
    _store.runInTransaction(TxMode.write, () {
      if (notebook.notes.any((n) => n.id == note.id)) return;
      notebook.notes.add(note);
      _notebooks.put(notebook);
      // The edge travels in the metadata record, so only the metadata version
      // moves — never the chunk-set version (spec FR13).
      note.versionCounter++;
      note.updatedAt = _nowUtc();
      _notes.put(note);
    });
  }

  @override
  void detach(String noteUuid, String notebookUuid) {
    final note = _requireNote(noteUuid);
    final notebook = _requireNotebook(notebookUuid);
    _store.runInTransaction(TxMode.write, () {
      // `removeWhere` on the id, never `remove`: ObjectBox entities have no
      // value equality, so `remove` compares by identity and silently fails.
      final before = notebook.notes.length;
      notebook.notes.removeWhere((n) => n.id == note.id);
      if (notebook.notes.length == before) return;
      _notebooks.put(notebook);
      note.versionCounter++;
      note.updatedAt = _nowUtc();
      _notes.put(note);
    });
  }

  @override
  void deleteNote(String noteUuid) {
    final note = _requireNote(noteUuid);
    _store.runInTransaction(TxMode.write, () {
      cascadeNoteRows(_store, note);
    });
  }

  @override
  Note? byUuid(String uuid) {
    final note = _findNoteOrNull(uuid);
    if (note == null) return null;
    final document = _findDocument(note.id);
    return note.toDomain(body: noteBodyOf(document) ?? '');
  }

  @override
  List<NoteSummary> listForNotebook(String notebookUuid) {
    final notebook = _findNotebook(notebookUuid);
    if (notebook == null) return const [];
    // Reading the relation loads the note rows (metadata only); the body lives
    // in a separate row and is never touched here (spec NFR4).
    final notes = notebook.notes.toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return notes.map((n) => n.toSummary()).toList();
  }

  @override
  List<String> inProcessNoteUuids() {
    final query = _notes
        .query(ObNote_.embeddingState.equals(NoteEmbeddingState.inProcess.storage))
        .build();
    try {
      return query.find().map((note) => note.uuid).toList();
    } finally {
      query.close();
    }
  }

  // --- helpers --------------------------------------------------------------

  void _removeChunksFor(int noteId) {
    final query = _chunks.query(ObNoteChunk_.noteId.equals(noteId)).build();
    try {
      query.remove();
    } finally {
      query.close();
    }
  }

  ObNote? _findNoteOrNull(String uuid) {
    final query = _notes.query(ObNote_.uuid.equals(uuid)).build();
    try {
      return query.findFirst();
    } finally {
      query.close();
    }
  }

  ObNote _requireNote(String uuid) {
    final note = _findNoteOrNull(uuid);
    if (note == null) throw StateError('no note with uuid $uuid');
    return note;
  }

  ObNoteDocument _requireDocument(int noteId) {
    final query =
        _documents.query(ObNoteDocument_.noteId.equals(noteId)).build();
    try {
      final entity = query.findFirst();
      if (entity == null) throw StateError('no note document for note $noteId');
      return entity;
    } finally {
      query.close();
    }
  }

  ObNoteDocument? _findDocument(int noteId) {
    final query =
        _documents.query(ObNoteDocument_.noteId.equals(noteId)).build();
    try {
      return query.findFirst();
    } finally {
      query.close();
    }
  }

  ObNotebook _requireNotebook(String uuid) {
    final query = _notebooks.query(ObNotebook_.uuid.equals(uuid)).build();
    try {
      final entity = query.findFirst();
      if (entity == null) throw StateError('no notebook with uuid $uuid');
      return entity;
    } finally {
      query.close();
    }
  }

  ObNotebook? _findNotebook(String uuid) {
    final query = _notebooks.query(ObNotebook_.uuid.equals(uuid)).build();
    try {
      return query.findFirst();
    } finally {
      query.close();
    }
  }

  static DateTime _nowUtc() => DateTime.fromMillisecondsSinceEpoch(
        DateTime.now().toUtc().millisecondsSinceEpoch,
        isUtc: true,
      );
}

/// Removes a note and every child row in one transaction's scope (spec FR14).
///
/// A **free function** so there is exactly one note cascade: `deleteNote` and
/// the notebook-delete cascade both call it. ObjectBox will not cascade for us;
/// dropping only the note row would leave chunks, a body, and messages behind.
///
/// The caller owns the transaction; this never opens one, so it joins whatever
/// transaction the caller is in.
void cascadeNoteRows(Store store, ObNote note) {
  final chunks = store.box<ObNoteChunk>().query(ObNoteChunk_.noteId.equals(note.id)).build();
  try {
    chunks.remove();
  } finally {
    chunks.close();
  }

  final documents =
      store.box<ObNoteDocument>().query(ObNoteDocument_.noteId.equals(note.id)).build();
  try {
    documents.remove();
  } finally {
    documents.close();
  }

  final messages =
      store.box<ObChatMessage>().query(ObChatMessage_.noteId.equals(note.id)).build();
  try {
    messages.remove();
  } finally {
    messages.close();
  }

  store.box<ObNote>().remove(note.id);
}

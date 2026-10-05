import 'package:mylittlenotebooks/data/objectbox/ob_chunk.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_document.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_note.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_note_chunk.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_note_document.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_notebook.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_publication.dart';
import 'package:mylittlenotebooks/objectbox.g.dart';

/// Resolves uuids from an incoming payload to this device's local int ids
/// (spec FR5).
///
/// **The seven reference sites.** ObjectBox stores a `ToOne`/`ToMany` as
/// relation rows *separate* from the denormalized int column, so **both** must be
/// rewritten and they must agree afterwards. That gives seven sites across four
/// entities:
///
/// | # | Entity | Reference | Kind |
/// |---|---|---|---|
/// | 1 | `ObChunk` | `publicationId` | denormalized int column |
/// | 2 | `ObChunk` | `publication` | ToOne |
/// | 3 | `ObDocument` | `publicationId` | denormalized int column |
/// | 4 | `ObDocument` | `publication` | ToOne |
/// | 5 | `ObNotebook` | `publications` | ToMany |
/// | 6 | `ObPublication` | `document` | ToOne |
/// | 7 | `ObPublication` | `chunks` | ToMany |
/// | 8 | `ObNote` | `notebooks` | ToMany (`@Backlink('notes')`) |
/// | 9 | `ObNoteChunk` | `noteId` | denormalized int column |
/// | 10 | `ObNoteChunk` | `note` | ToOne (`@TargetIdProperty('noteRef')`) |
/// | 11 | `ObNoteDocument` | `noteId` | denormalized int column |
/// | 12 | `ObNoteDocument` | `note` | ToOne (`@TargetIdProperty('noteOwnerId')`) |
/// | 13 | `ObNote` | `document` | ToOne |
/// | 14 | `ObNote` | `chunks` | ToMany (`@Backlink('note')`) |
///
/// **This list is enumerated deliberately, not discovered reflectively.** A
/// reflective implementation passes its tests while a site is silently missed,
/// and the failure is invisible: a chunk whose `publicationId` was not rewritten
/// still exists, still counts, still renders in a list — and is returned by
/// scoped search, because the filter reads `publicationId`.
///
/// ObjectBox makes it worse. Deleting a publication row *without* its cascade
/// leaves chunks behind and ObjectBox **zeroes the `ToOne` target id while
/// leaving the denormalized `publicationId` at the dead int** (measured). So the
/// two representations can diverge without anything throwing.
class UuidScope {
  UuidScope(Store store)
      : _notebooks = store.box<ObNotebook>(),
        _publications = store.box<ObPublication>(),
        _documents = store.box<ObDocument>(),
        _chunks = store.box<ObChunk>(),
        _notes = store.box<ObNote>(),
        _noteDocuments = store.box<ObNoteDocument>(),
        _noteChunks = store.box<ObNoteChunk>();

  final Box<ObNotebook> _notebooks;
  final Box<ObPublication> _publications;
  final Box<ObDocument> _documents;
  final Box<ObChunk> _chunks;
  final Box<ObNote> _notes;
  final Box<ObNoteDocument> _noteDocuments;
  final Box<ObNoteChunk> _noteChunks;

  /// Every uuid seen this ingest, mapped to its local int. Retained so a payload
  /// referring to the same publication from both a chunk and the document row
  /// resolves once.
  final Map<String, int> _resolved = {};

  // --- 1 and 2: the publication a chunk points at ---------------------------

  /// Local int for [uuid], creating the publication row if this device has never
  /// seen it. A well-formed uuid for an unknown object means "create it" —
  /// rejecting it would break ingest entirely.
  int resolvePublication(String uuid) {
    final cached = _resolved[uuid];
    if (cached != null) return cached;

    final existing = _publications
        .query(ObPublication_.uuid.equals(uuid))
        .build()
        .findFirst();
    if (existing != null) {
      _resolved[uuid] = existing.id;
      return existing.id;
    }

    final created = ObPublication(
      uuid: uuid,
      title: '',
      byteSize: 0,
      importedAt: DateTime.now().toUtc(),
      embeddingModelId: '',
    );
    _publications.put(created);
    _resolved[uuid] = created.id;
    return created.id;
  }

  // --- 3 and 4: the publication a document points at ------------------------

  int resolveDocument(String uuid, int publicationId) {
    final existing = _documents
        .query(ObDocument_.uuid.equals(uuid))
        .build()
        .findFirst();
    if (existing != null) {
      // Site 3: keep the denormalized column in step with the relation.
      existing.publicationId = publicationId;
      existing.publication.targetId = publicationId;
      _documents.put(existing);
      return existing.id;
    }

    final created = ObDocument(
      uuid: uuid,
      publicationId: publicationId,
      markdown: '',
    );
    created.publication.targetId = publicationId;
    _documents.put(created);
    return created.id;
  }

  // --- 5: a notebook's publication edges ------------------------------------

  int resolveNotebook(String uuid) {
    final cached = _resolved['nb:$uuid'];
    if (cached != null) return cached;

    final existing =
        _notebooks.query(ObNotebook_.uuid.equals(uuid)).build().findFirst();
    if (existing != null) {
      _resolved['nb:$uuid'] = existing.id;
      return existing.id;
    }

    final created = ObNotebook(
      uuid: uuid,
      title: '',
      createdAt: DateTime.now().toUtc(),
    );
    _notebooks.put(created);
    _resolved['nb:$uuid'] = created.id;
    return created.id;
  }

  /// Site 5 — attaches [publicationId] to [notebookId].
  ///
  /// Uses `removeWhere` on the id rather than `remove`: `ToMany` is a
  /// `ListMixin` and entities have no value equality, so `remove` compares by
  /// *identity* and silently fails against a freshly queried instance.
  void attachPublicationToNotebook({
    required int notebookId,
    required int publicationId,
  }) {
    final notebook = _notebooks.get(notebookId);
    if (notebook == null) throw StateError('no notebook with id $notebookId');

    final already = notebook.publications.any((p) => p.id == publicationId);
    if (already) return;

    notebook.publications.add(_publications.get(publicationId)!);
    _notebooks.put(notebook);
  }

  // --- 6 and 7: the publication's own outbound edges ------------------------

  /// Site 6 — points [publicationId]'s document at [documentId].
  void attachDocumentToPublication({
    required int publicationId,
    required int documentId,
  }) {
    final publication = _publications.get(publicationId);
    if (publication == null) {
      throw StateError('no publication with id $publicationId');
    }
    final document = _documents.get(documentId);
    if (document == null) throw StateError('no document with id $documentId');

    publication.document.targetId = documentId;
    _publications.put(publication);
  }

  /// Site 7 — attaches a chunk to its publication's `chunks` ToMany.
  ///
  /// `replaceChunks` already maintains this edge via the `ObChunk.publication`
  /// ToOne and the backlink, so this exists for completeness of the site list
  /// and is a no-op when the backlink has already registered the relation.
  void attachChunkToPublication({
    required int publicationId,
    required int chunkId,
  }) {
    final publication = _publications.get(publicationId);
    if (publication == null) {
      throw StateError('no publication with id $publicationId');
    }
    if (publication.chunks.any((c) => c.id == chunkId)) return;

    publication.chunks.add(_chunks.get(chunkId)!);
    _publications.put(publication);
  }

  // --- 8: a note's notebook edges (spec FR21) -------------------------------

  /// Site 8 — local int for a note uuid, creating the row if unknown.
  int resolveNote(String uuid) {
    final cached = _resolved['note:$uuid'];
    if (cached != null) return cached;

    final existing =
        _notes.query(ObNote_.uuid.equals(uuid)).build().findFirst();
    if (existing != null) {
      _resolved['note:$uuid'] = existing.id;
      return existing.id;
    }

    final now = DateTime.fromMillisecondsSinceEpoch(
      DateTime.now().toUtc().millisecondsSinceEpoch,
      isUtc: true,
    );
    final created = ObNote(
      uuid: uuid,
      title: null,
      createdAt: now,
      updatedAt: now,
    );
    _notes.put(created);
    _resolved['note:$uuid'] = created.id;
    return created.id;
  }

  /// Site 8 — attaches [noteId] to [notebookId].
  void attachNoteToNotebook({
    required int notebookId,
    required int noteId,
  }) {
    final notebook = _notebooks.get(notebookId);
    if (notebook == null) throw StateError('no notebook with id $notebookId');

    if (notebook.notes.any((n) => n.id == noteId)) return;

    notebook.notes.add(_notes.get(noteId)!);
    _notebooks.put(notebook);
  }

  // --- 9 and 10: the note a chunk points at ---------------------------------

  // --- 11 and 12: the note a document points at -----------------------------

  /// Sites 11 and 12 — local int for a note body uuid, creating the row if
  /// unknown, and keeping the denormalized column in step with the relation.
  int resolveNoteDocument(String uuid, int noteId) {
    final existing = _noteDocuments
        .query(ObNoteDocument_.uuid.equals(uuid))
        .build()
        .findFirst();
    if (existing != null) {
      existing.noteId = noteId;
      existing.note.targetId = noteId;
      _noteDocuments.put(existing);
      return existing.id;
    }

    final created = ObNoteDocument(
      uuid: uuid,
      noteId: noteId,
      markdown: '',
    );
    created.note.targetId = noteId;
    _noteDocuments.put(created);
    return created.id;
  }

  // --- 13 and 14: the note's own outbound edges -----------------------------

  /// Site 13 — points [noteId]'s document at [documentId].
  void attachNoteDocument({
    required int noteId,
    required int documentId,
  }) {
    final note = _notes.get(noteId);
    if (note == null) throw StateError('no note with id $noteId');
    final document = _noteDocuments.get(documentId);
    if (document == null) throw StateError('no note document with id $documentId');

    note.document.targetId = documentId;
    _notes.put(note);
  }

  /// Site 14 — attaches a chunk to its note's `chunks` ToMany.
  void attachNoteChunk({
    required int noteId,
    required int chunkId,
  }) {
    final note = _notes.get(noteId);
    if (note == null) throw StateError('no note with id $noteId');
    if (note.chunks.any((c) => c.id == chunkId)) return;

    note.chunks.add(_noteChunks.get(chunkId)!);
    _notes.put(note);
  }
}

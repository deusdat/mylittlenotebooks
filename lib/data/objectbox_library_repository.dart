import 'package:mylittlenotebooks/data/embedding_validation.dart';
import 'package:mylittlenotebooks/data/identity.dart';
import 'package:mylittlenotebooks/data/library_repository.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_chunk.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_document.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_notebook.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_publication.dart';
import 'package:mylittlenotebooks/data/objectbox_note_repository.dart';
import 'package:mylittlenotebooks/domain_mapping.dart';
import 'package:mylittlenotebooks/models/chunk.dart';
import 'package:mylittlenotebooks/models/publication.dart';
import 'package:mylittlenotebooks/objectbox.g.dart';

/// ObjectBox-backed [LibraryRepository].
///
/// The transaction rule this class exists to enforce: **any write that would
/// leave an inconsistency if interrupted runs in one
/// `runInTransaction(TxMode.write, …)`** (spec FR10, plan §G). A publication
/// whose chunk set is half-replaced, or whose `chunkCount` disagrees with its
/// chunks, must never be observable.
class ObjectBoxLibraryRepository implements LibraryRepository {
  ObjectBoxLibraryRepository(this._store)
      : _publications = _store.box<ObPublication>(),
        _chunks = _store.box<ObChunk>(),
        _notebooks = _store.box<ObNotebook>(),
        _documents = _store.box<ObDocument>();

  final Store _store;
  final Box<ObPublication> _publications;
  final Box<ObChunk> _chunks;
  final Box<ObNotebook> _notebooks;
  final Box<ObDocument> _documents;

  @override
  Publication create({
    required String title,
    required String sourceMarkdown,
    required String embeddingModelId,
  }) {
    if (sourceMarkdown.trim().isEmpty) {
      throw const EmptySourceException();
    }
    final byteSize = utf8ByteLength(sourceMarkdown);

    late final ObPublication entity;
    _store.runInTransaction(TxMode.write, () {
      entity = ObPublication(
        uuid: newUuidV7(),
        title: title,
        // The document text is stored in its own row so list paths never read
        // it (spec NFR6, spec correction 3).
        byteSize: byteSize,
        // Truncated to the store's millisecond precision. `PropertyType.dateUtc`
        // keeps milliseconds, so returning a microsecond-precision value here
        // would hand the caller a timestamp the database cannot reproduce — the
        // object returned by `create` and the object read back by `byUuid` would
        // differ (spec AC4).
        importedAt: _nowUtc(),
        embeddingModelId: embeddingModelId,
        // A creation is a modification, so the record starts at 1 rather than 0.
        // It matters only that this row has a version at all: a record with no
        // version is indistinguishable from one a peer has already seen.
        versionCounter: 1,
      );
      _publications.put(entity);

      final document = ObDocument(
        uuid: documentUuidFor(entity.uuid),
        publicationId: entity.id,
        markdown: sourceMarkdown,
        versionCounter: 1,
      );
      document.publication.targetId = entity.id;
      _documents.put(document);
    });

    return entity.toDomain(sourceMarkdown: sourceMarkdown);
  }

  /// UTC, truncated to the millisecond precision the store persists.
  static DateTime _nowUtc() {
    final now = DateTime.now().toUtc();
    return DateTime.fromMillisecondsSinceEpoch(
      now.millisecondsSinceEpoch,
      isUtc: true,
    );
  }

  @override
  void replaceChunks(String publicationUuid, List<ChunkDraft> drafts) {
    // Validate **every** draft before opening the transaction, so a bad vector
    // can never leave a partial write behind (spec FR8, AC8).
    for (final draft in drafts) {
      validateEmbedding(draft.embedding);
    }

    final publication = _requirePublication(publicationUuid);

    _store.runInTransaction(TxMode.write, () {
      // Remove-then-insert, so a re-index cannot leave stale chunks behind and
      // cannot duplicate the ones it rewrites.
      final stale = _chunks
          .query(ObChunk_.publicationId.equals(publication.id))
          .build();
      try {
        stale.remove();
      } finally {
        stale.close();
      }

      final entities = drafts
          .map((d) => d.toEntity(
                publicationId: publication.id,
                publicationUuid: publication.uuid,
              ))
          .toList();
      _chunks.putMany(entities);

      // The denormalised count is written here and **only** here (spec FR9,
      // plan R8). Inside the transaction, so a rollback restores it.
      publication.chunkCount = entities.length;
      // Replacing a chunk set is what advances the chunk-set version, and it is
      // tracked separately from the publication's own sync version so that a
      // rename does not drag the whole set to a peer (peer-sync FR5a).
      publication.chunkSetVersion++;
      // A re-index is also a metadata change — the publication's own version
      // moves with it (peer-sync plan §G), so a peer learns the record changed
      // even when only the set did.
      publication.versionCounter++;
      _publications.put(publication);
    });
  }

  @override
  void deletePublication(String publicationUuid) {
    final publication = _requirePublication(publicationUuid);
    _store.runInTransaction(TxMode.write, () {
      _cascadePublication(publication);
    });
  }

  /// Removes a publication and its children: chunks, document, then the row.
  ///
  /// **The one place this cascade exists.** `deletePublication` and the
  /// notebook exclusive-cascade both call it, and the sync module routes its
  /// local deletes through them, so the "delete a publication" operation cannot
  /// drift into three copies.
  ///
  /// ObjectBox will not do this for us: dropping only the publication row
  /// leaves its chunks behind with a zeroed `ToOne` and a live denormalised
  /// `publicationId`, so they keep counting and keep matching scoped search, and
  /// nothing throws (peer-sync FR17).
  void _cascadePublication(ObPublication publication) {
    final query = _chunks
        .query(ObChunk_.publicationId.equals(publication.id))
        .build();
    try {
      query.remove();
    } finally {
      query.close();
    }

    // The document text goes with it, or the store would grow without bound
    // and a re-import under the same uuid could resurrect stale text.
    final documents = _documents
        .query(ObDocument_.publicationId.equals(publication.id))
        .build();
    try {
      documents.remove();
    } finally {
      documents.close();
    }

    _publications.remove(publication.id);
  }

  @override
  void attach(String publicationUuid, String notebookUuid) {
    final publication = _requirePublication(publicationUuid);
    final notebook = _requireNotebook(notebookUuid);
    _store.runInTransaction(TxMode.write, () {
      // `ToMany` models the association as a set, so re-adding is naturally
      // idempotent — but checking first keeps the intent explicit and avoids a
      // pointless write (spec FR11, AC3).
      final already = notebook.publications.any((p) => p.id == publication.id);
      if (already) return;
      notebook.publications.add(publication);
      _notebooks.put(notebook);
      // The association travels in the metadata record, so an attach advances
      // the publication's own version — and only that one (peer-sync plan §G).
      // Bumping [chunkSetVersion] here would ship every chunk for a rename.
      publication.versionCounter++;
      _publications.put(publication);
    });
  }

  @override
  void detach(String publicationUuid, String notebookUuid) {
    final publication = _requirePublication(publicationUuid);
    final notebook = _requireNotebook(notebookUuid);
    _store.runInTransaction(TxMode.write, () {
      // `removeWhere` on the id, **not** `remove(publication)`.
      //
      // `ToMany` is a `ListMixin` and ObjectBox entities have no value
      // equality, so `List.remove` compares by *identity*. The entity returned
      // by `_requirePublication` is a different instance from the one inside
      // the relation, and `remove` would silently return false — detaching
      // would appear to succeed and change nothing. Comparing ids is what
      // actually expresses the intent (spec FR11, AC3).
      final before = notebook.publications.length;
      notebook.publications.removeWhere((p) => p.id == publication.id);
      if (notebook.publications.length != before) {
        _notebooks.put(notebook);
        // A detach is a metadata change for the same reason an attach is, and
        // for the same directional reason: metadata only.
        publication.versionCounter++;
        _publications.put(publication);
      }
    });
  }

  @override
  NotebookCascade deleteNotebook(String notebookUuid) {
    final notebook = _requireNotebook(notebookUuid);
    final publications = <CascadedPublication>[];
    final notes = <CascadedNote>[];
    _store.runInTransaction(TxMode.write, () {
      // Copy the edges first: cascading a publication mutates the `ToMany` we
      // would otherwise be iterating.
      final attached = notebook.publications.toList();
      for (final publication in attached) {
        // Exclusive means this notebook is its only association. A publication
        // with any other notebook is shared, and deleting it would be
        // unrecoverable data loss the user did not ask for (spec FR1, FR3).
        if (publication.notebooks.length > 1) continue;
        // Captured before the row goes, for the caller's tombstone (spec FR5).
        publications.add(CascadedPublication(
          uuid: publication.uuid,
          versionCounter: publication.versionCounter,
        ));
        _cascadePublication(publication);
      }

      // Notes cascade by the same exclusivity rule (spec FR15): a note attached
      // to any other notebook is shared and survives, holding one fewer
      // notebook. `cascadeNoteRows` is the same cascade `deleteNote` uses.
      final attachedNotes = notebook.notes.toList();
      for (final note in attachedNotes) {
        if (note.notebooks.length > 1) continue;
        notes.add(CascadedNote(
          uuid: note.uuid,
          versionCounter: note.versionCounter,
        ));
        cascadeNoteRows(_store, note);
      }

      // Removing the notebook removes its `ToMany` edges; shared publications
      // and notes are left holding one fewer notebook.
      _notebooks.remove(notebook.id);
    });
    return NotebookCascade(publications: publications, notes: notes);
  }

  ObPublication _requirePublication(String uuid) {
    final query = _publications.query(ObPublication_.uuid.equals(uuid)).build();
    try {
      final found = query.findFirst();
      if (found == null) throw StateError('no publication with uuid $uuid');
      return found;
    } finally {
      query.close();
    }
  }

  ObNotebook _requireNotebook(String uuid) {
    final query = _notebooks.query(ObNotebook_.uuid.equals(uuid)).build();
    try {
      final found = query.findFirst();
      if (found == null) throw StateError('no notebook with uuid $uuid');
      return found;
    } finally {
      query.close();
    }
  }
}

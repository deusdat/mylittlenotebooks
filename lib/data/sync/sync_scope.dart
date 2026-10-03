import 'package:mylittlenotebooks/data/objectbox/ob_chunk.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_document.dart';
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
        _chunks = store.box<ObChunk>();

  final Box<ObNotebook> _notebooks;
  final Box<ObPublication> _publications;
  final Box<ObDocument> _documents;
  final Box<ObChunk> _chunks;

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
}

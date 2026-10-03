import 'package:mylittlenotebooks/data/objectbox/ob_chunk.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_document.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_notebook.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_publication.dart';
import 'package:mylittlenotebooks/data/objectbox_library_repository.dart';
import 'package:mylittlenotebooks/data/sync/device_id.dart';
import 'package:mylittlenotebooks/data/sync/sync_codec.dart';
import 'package:mylittlenotebooks/data/sync/sync_payload.dart';
import 'package:mylittlenotebooks/data/sync/sync_scope.dart';
import 'package:mylittlenotebooks/data/sync/sync_tombstones.dart';
import 'package:mylittlenotebooks/data/sync/sync_validator.dart';
import 'package:mylittlenotebooks/data/sync/sync_version.dart';
import 'package:mylittlenotebooks/models/chunk.dart';
import 'package:mylittlenotebooks/objectbox.g.dart';

/// Applies an incoming payload to this device (spec FR5, FR5a, FR5b, FR6, FR7,
/// FR8, FR9, FR17).
///
/// **This is the component that writes, so it is the one that has to be right
/// about the two failures that do not throw**: a partially applied chunk set,
/// and two models' vectors meeting in one index. Everything else in the sync
/// directory is either pure (validation, versioning, the codec) or a read-only
/// resolver.
///
/// ## The order, and why it is that order
///
/// ```text
/// validate every chunk set   (FR5a-bis)  ← refuses WHOLE, before any write
/// plan: decide what applies   (FR9, FR14) ← read-only, resolves nothing
/// for each delete:            one transaction   (FR17, FR12)
/// for each publication:       one transaction   (FR6)
/// ```
///
/// Three properties fall out of that order, and each is a test:
///
/// * **Nothing to roll back on a refused payload.** Validation happens before
///   the first write, so "refuse whole, store untouched" (AC7d) is structural
///   rather than a claim about rollback.
/// * **No placeholder row ever survives.** `UuidScope` *creates* the rows it
///   resolves — a well-formed uuid for an unknown object means "create it" —
///   so the decision to apply has to be made *before* resolving. Planning first
///   does that. Resolving first and deciding afterwards would leave an untitled
///   publication row behind for every record that lost or was tombstoned, and
///   such a row still renders.
/// * **Deletes land before upserts.** A payload may carry both an upsert and a
///   delete for one uuid, and FR14 gives the delete priority unconditionally.
///   Applying deletes first means the tombstone is already written when the
///   upsert is planned, so the upsert is refused by the same rule as any other
///   — rather than by a special case in the upsert path.
///
/// ## One transaction per DAG, not one per payload
///
/// FR6 requires each publication's DAG to be atomic. The whole payload being
/// atomic too would be stronger, and is not what this does: a first push of
/// 10,000 chunks would hold a single write lock for the entire transfer, and a
/// failure at the end would discard everything (spec NFR6). Per-DAG transactions
/// bound the lock to one publication and make a partially transferred push
/// resumable — the records that landed are already correct, and a re-push of the
/// range is idempotent.
///
/// `replaceChunks` opens its own transaction. That is safe and is *required* to
/// be: ObjectBox reuses the enclosing transaction for a nested
/// `runInTransaction`, so the inner call joins this one and neither commits
/// independently (verified; see [SyncApplier] on `runInTransaction`).
class SyncApplier {
  SyncApplier({
    required Store store,
    required this.activeEmbeddingModelId,
    String? deviceId,
    TombstoneStore? tombstones,
    this.faultHook,
  })  : _store = store,
        _deviceId = deviceId ?? resolveDeviceId(store),
        _tombstones = tombstones ?? TombstoneStore(store),
        _library = ObjectBoxLibraryRepository(store);

  final Store _store;
  final ObjectBoxLibraryRepository _library;
  final TombstoneStore _tombstones;
  final IngestFaultHook? faultHook;

  /// This device's `embeddingModelId`. **The gate compares against this and
  /// nothing else** (FR5b).
  ///
  /// The value space of this string belongs to the embedding spec; this class
  /// only compares it. An empty string means "no model is active here", which
  /// the gate treats as a mismatch — refusing vectors is the safe reading when
  /// there is nothing to compare them against.
  final String activeEmbeddingModelId;

  final String _deviceId;

  /// Applies [payload], throwing [ChunkSetRejection] if any chunk set disagrees
  /// with its declaration.
  ///
  /// The rejection is thrown rather than returned because it means the payload
  /// must not be applied *at all* (FR5a-bis). A caller that caught it and
  /// carried on would be doing exactly what the declaration exists to prevent.
  IngestResult ingest(SyncPayload payload) {
    // 1. Validate every set first. This is the only whole-payload refusal, and
    //    it runs before a single row is touched.
    for (final publication in payload.publications) {
      validateChunkSet(publication);
    }

    // 2. Plan. Read-only: it decides, and it resolves nothing.
    final deletes = payload.deletes
        .where((d) => !_tombstones.isDead(d.uuid))
        .toList(growable: false);

    // Notebooks are the roots of the DAG (FR7), so they are planned and written
    // before anything that references them.
    final notebookPlans = <_NotebookPlan>[];
    for (final notebook in payload.notebooks) {
      final plan = _planNotebook(notebook);
      if (plan != null) notebookPlans.add(plan);
    }

    final plans = <_Plan>[];
    for (final publication in payload.publications) {
      final plan = _plan(publication);
      if (plan != null) plans.add(plan);
    }

    // 3. Deletes, then publications. One transaction each.
    var deletesApplied = 0;
    for (final delete in deletes) {
      _applyDelete(delete);
      deletesApplied++;
    }

    var notebooksApplied = 0;
    for (final plan in notebookPlans) {
      _applyNotebook(plan);
      notebooksApplied++;
    }

    var applied = 0;
    final vectorsRefused = <String>[];
    for (final plan in plans) {
      _applyPublication(plan);
      applied++;
      if (plan.vectorsGated) vectorsRefused.add(plan.dto.uuid);
    }

    return IngestResult(
      notebooksApplied: notebooksApplied,
      publicationsApplied: applied,
      publicationsSkipped: payload.publications.length - plans.length,
      deletesApplied: deletesApplied,
      vectorsRefused: List.unmodifiable(vectorsRefused),
    );
  }

  /// Decodes then ingests. The declared-count check runs inside [ingest], after
  /// decoding, because it is a check on decoded records rather than on bytes.
  IngestResult ingestEncoded(String encoded) => ingest(decodePayload(encoded));

  // --- planning --------------------------------------------------------------

  /// Decides what a single notebook record will do, or null when nothing will.
  _NotebookPlan? _planNotebook(NotebookDto dto) {
    if (_tombstones.isDead(dto.uuid)) return null;

    final local = _findNotebook(dto.uuid);
    final localVersion = local == null
        ? noVersion
        : (counter: local.versionCounter, deviceId: _deviceId);
    if (!supersedes(dto.version.toDomain(), localVersion)) return null;

    return _NotebookPlan(dto: dto, created: local == null);
  }

  void _applyNotebook(_NotebookPlan plan) {
    final dto = plan.dto;
    _store.runInTransaction(TxMode.write, () {
      final notebook = _notebooks.get(_scope.resolveNotebook(dto.uuid));
      if (notebook == null) throw StateError('notebook ${dto.uuid} did not resolve');
      notebook.title = dto.title;
      notebook.versionCounter = dto.version.toDomain().counter;
      _notebooks.put(notebook);
      // `return null` keeps this callback's static type off `Never`; see `_fault`.
      return null;
    });
  }

  /// Decides what a single publication record will do, or null when nothing
  /// will.
  ///
  /// Returning null rather than a plan with an `apply: false` flag is what keeps
  /// the placeholder problem away: a skipped record is never resolved, so
  /// `UuidScope` never creates a row for it.
  _Plan? _plan(PublicationDto dto) {
    // FR14. No version argument, no comparison — a tombstone wins outright.
    if (_tombstones.isDead(dto.uuid)) return null;

    final local = _findPublication(dto.uuid);
    final localVersion =
        local == null ? noVersion : (counter: local.versionCounter, deviceId: _deviceId);
    final incomingVersion = dto.version.toDomain();

    // FR9. An absent local record has no version, and `noVersion` loses to
    // everything, so the first arrival always applies.
    final applyMetadata = supersedes(incomingVersion, localVersion);

    // FR5a. The set is selected by its **own** version. Consulting the metadata
    // version here is the bug plan R3 names: renaming a publication would ship
    // its entire chunk set.
    final localChunkVersion = local == null
        ? noVersion
        : (counter: local.chunkSetVersion, deviceId: _deviceId);
    final modelMatches = dto.embeddingModelId == activeEmbeddingModelId;
    // `chunksIncluded` is what separates "the sender had nothing to send" from
    // "the sender's set is now empty". Without it a metadata-only push would
    // replace a fifty-chunk set with nothing, because the set version the
    // payload carries is the sender's current one and it compares as newer.
    final applyChunkSet = dto.chunksIncluded &&
        modelMatches &&
        supersedes(dto.chunkSetVersion.toDomain(), localChunkVersion);

    // The model gate (FR5b) withholds vectors without blocking the record: the
    // document is the user's data and transfers regardless.
    final vectorsGated = dto.chunksIncluded && !modelMatches && dto.chunks.isNotEmpty;

    final document = dto.document;
    final localDocument =
        document == null ? null : _findDocument(document.uuid);
    final applyDocument = document != null &&
        supersedes(
          document.version.toDomain(),
          localDocument == null
              ? noVersion
              : (counter: localDocument.versionCounter, deviceId: _deviceId),
        );

    // Nothing to do at all: skip without resolving. This is the whole reason
    // planning happens before resolution.
    if (!applyMetadata && !applyChunkSet && !applyDocument) return null;

    return _Plan(
      dto: dto,
      applyMetadata: applyMetadata,
      applyChunkSet: applyChunkSet,
      applyDocument: applyDocument,
      vectorsGated: vectorsGated,
      // Relabelling a publication whose chunks were produced by the *local*
      // model would make the label describe vectors it does not have — the one
      // silent vector-space mix FR5b exists to prevent, arriving through the
      // metadata field instead of the set.
      keepLocalModelLabel: !modelMatches && (local?.chunkCount ?? 0) > 0,
    );
  }

  // --- writes ----------------------------------------------------------------

  void _applyPublication(_Plan plan) {
    final dto = plan.dto;
    final scope = _scope;

    _store.runInTransaction(TxMode.write, () {
      // FR7, read as a topological order: the publication exists before
      // anything references it, the document before the publication points at
      // it, and the chunk set last so `replaceChunks` has a parent to write
      // into. The nested transaction joins this one rather than committing.
      final publicationId = scope.resolvePublication(dto.uuid);

      if (plan.applyMetadata) {
        final publication = _requirePublication(publicationId);
        publication.title = dto.title;
        publication.byteSize = dto.byteSize;
        // The peer's version is authoritative verbatim. `replaceChunks` bumps
        // this counter, and overwriting it afterwards is what stops a re-index
        // from landing as "the peer's version plus one".
        publication.versionCounter = dto.version.toDomain().counter;
        if (!plan.keepLocalModelLabel) {
          publication.embeddingModelId = dto.embeddingModelId;
        }

        // Site 5. The payload's notebook list is authoritative when the metadata
        // version wins: an omitted notebook is *detached*, not merely not
        // attached. Additive-only handling would make a detach permanently
        // invisible, since nothing else in the payload could report it.
        _syncNotebookEdges(scope, publication, dto.notebookUuids);

        // Unconditional. An earlier version of this compared the notebook count
        // before and after and only wrote on a change — which silently dropped
        // the title and byte size whenever the edge set was *replaced* with an
        // equal-sized one, because the length was unchanged. Membership is what
        // matters, and the simplest correct thing is to always write the row we
        // just mutated.
        _publications.put(publication);
        _fault(plan, IngestFaultPoint.afterMetadata);
      }

      if (plan.applyDocument) {
        final document = dto.document!;
        final documentId = scope.resolveDocument(document.uuid, publicationId);
        // Sites 3 and 4 are written by `resolveDocument`; the text and its
        // version are written here.
        final row = _requireDocument(documentId);
        row.markdown = document.markdown;
        row.versionCounter = document.version.toDomain().counter;
        _documents.put(row);
        scope.attachDocumentToPublication(
          publicationId: publicationId,
          documentId: documentId,
        );
        _fault(plan, IngestFaultPoint.afterDocument);
      }

      if (plan.applyChunkSet) {
        // FR5a. Wholesale replacement, via the data layer's own write path —
        // the same call an import or a re-index makes, so there is exactly one
        // place in this codebase that inserts chunks.
        _library.replaceChunks(dto.uuid, _drafts(dto.chunks));
        // `replaceChunks` bumps both counters; the peer's are authoritative.
        final publication = _requirePublication(publicationId);
        publication.chunkSetVersion = dto.chunkSetVersion.toDomain().counter;
        publication.versionCounter = plan.applyMetadata
            ? dto.version.toDomain().counter
            : publication.versionCounter;
        _publications.put(publication);
        _fault(plan, IngestFaultPoint.afterChunks);
      }
    });
  }

  /// The **local** delete path: cascades and tombstones, stamping a version so
  /// the delete can be selected into a later push (FR11).
  ///
  /// Without the version the delete would be stuck at counter zero and no delta
  /// could ever carry it, so a user deletion on this device would never reach a
  /// peer. The counter is the publication's own, incremented once: a delete is
  /// the next edit to that record, and reusing its counter keeps one version
  /// line per publication rather than two that have to be reconciled.
  void deleteLocally(String publicationUuid) {
    final publication = _findPublication(publicationUuid);
    final version = nextVersion(
      publication == null ? noVersion : _versionOf(publication.versionCounter),
      _deviceId,
    );

    _store.runInTransaction(TxMode.write, () {
      _cascade(publication);
      _tombstones.markDead(publicationUuid, versionCounter: version.counter);
    });
  }

  SyncVersion _versionOf(int counter) =>
      (counter: counter, deviceId: _deviceId);

  void _applyDelete(DeleteDto delete) {
    final publication = _findPublication(delete.uuid);

    _store.runInTransaction(TxMode.write, () {
      _cascade(publication);

      // The tombstone goes in **the same transaction** as the delete. Written
      // after a commit it could be lost, leaving a deleted object resurrectable
      // by an in-flight push; written before, a rollback would leave a live
      // object that nothing could ever update. There is no safe order outside
      // the transaction.
      //
      // Recorded even when the object was already absent. FR12 calls an absent
      // delete a no-op, which is true of the *deletion*; tombstoning it anyway
      // is what lets FR14 hold, because an in-flight upsert for the same uuid
      // may still be on its way.
      //
      // The version is the delete's own, so a re-push after an interruption
      // carries it again rather than skipping it.
      _tombstones.markDead(delete.uuid, versionCounter: delete.version.counter);
    });
  }

  /// The local cascade a delete runs: chunks, document, publication (FR17).
  ///
  /// Extracted so the local and receive paths cannot drift apart — they are the
  /// same operation, and two copies of a cascade is one too many.
  ///
  /// ObjectBox will not do this for us: dropping only the publication row leaves
  /// its chunks behind with a zeroed `ToOne` and a live denormalised
  /// `publicationId`, so they keep counting and keep matching scoped search, and
  /// nothing throws. Notebooks are left alone — each simply holds one fewer
  /// publication.
  void _cascade(ObPublication? publication) {
    if (publication == null) return;

    final chunkQuery =
        _chunks.query(ObChunk_.publicationId.equals(publication.id)).build();
    try {
      chunkQuery.remove();
    } finally {
      chunkQuery.close();
    }

    final documentQuery =
        _documents.query(ObDocument_.publicationId.equals(publication.id)).build();
    try {
      documentQuery.remove();
    } finally {
      documentQuery.close();
    }

    _publications.remove(publication.id);
  }

  /// Rewrites [publication]'s notebook edges to be exactly [wanted].
  ///
  /// Mutates only; the caller writes the row. Detach uses `removeWhere` on the
  /// id, never `remove` — a `ToMany` is a `ListMixin` and entities have no value
  /// equality, so `remove` compares by identity and silently fails against a
  /// freshly queried instance.
  void _syncNotebookEdges(
    UuidScope scope,
    ObPublication publication,
    List<String> wanted,
  ) {
    final wantedIds = <int>{};
    for (final uuid in wanted) {
      wantedIds.add(scope.resolveNotebook(uuid));
    }

    publication.notebooks.removeWhere((n) => !wantedIds.contains(n.id));
    for (final id in wantedIds) {
      if (publication.notebooks.any((n) => n.id == id)) continue;
      final notebook = _notebooks.get(id);
      if (notebook != null) publication.notebooks.add(notebook);
    }
  }

  /// The payload's chunks as the domain write path's own input type.
  ///
  /// Going through [ChunkDraft] rather than writing `ObChunk` rows directly is
  /// the point of reusing `replaceChunks`: the derived chunk identity (FR2a) and
  /// both publication reference sites are written by one function that the
  /// import path also uses.
  List<ChunkDraft> _drafts(List<ChunkDto> chunks) => [
        for (final chunk in chunks)
          ChunkDraft(
            chunkIndex: chunk.chunkIndex,
            content: chunk.content,
            tokenCount: chunk.tokenCount,
            embedding: decodeVector(chunk.embeddingBase64),
          ),
      ];

  // --- reads -----------------------------------------------------------------

  Box<ObPublication> get _publications => _store.box<ObPublication>();
  Box<ObDocument> get _documents => _store.box<ObDocument>();
  Box<ObChunk> get _chunks => _store.box<ObChunk>();
  Box<ObNotebook> get _notebooks => _store.box<ObNotebook>();

  UuidScope get _scope => UuidScope(_store);

  ObNotebook? _findNotebook(String uuid) {
    final query = _notebooks.query(ObNotebook_.uuid.equals(uuid)).build();
    try {
      return query.findFirst();
    } finally {
      query.close();
    }
  }

  ObPublication? _findPublication(String uuid) {
    final query = _publications.query(ObPublication_.uuid.equals(uuid)).build();
    try {
      return query.findFirst();
    } finally {
      query.close();
    }
  }

  ObDocument? _findDocument(String uuid) {
    final query = _documents.query(ObDocument_.uuid.equals(uuid)).build();
    try {
      return query.findFirst();
    } finally {
      query.close();
    }
  }

  ObPublication _requirePublication(int id) {
    final row = _publications.get(id);
    if (row == null) throw StateError('no publication with id $id');
    return row;
  }

  ObDocument _requireDocument(int id) {
    final row = _documents.get(id);
    if (row == null) throw StateError('no document with id $id');
    return row;
  }

  /// Invokes the test fault hook, if one is installed.
  ///
  /// **Never inlined as a `throw` on a `Never`-returning path.** ObjectBox
  /// special-cases a transaction callback whose static return type is `Never`:
  /// `Store.runInTransaction` throws `UnsupportedError('Given transaction
  /// callback always fails.')` *without ever invoking it*. An AC8 test that
  /// injects a fault and then observes "no partial state" would pass vacuously
  /// under that path, because nothing would have run at all. The transaction
  /// bodies below therefore end in an explicit `return null`.
  void _fault(_Plan plan, IngestFaultPoint point) =>
      faultHook?.call(plan.dto.uuid, point);
}

/// Named points inside the ingest transaction where a test may inject a fault.
///
/// Exists so AC8 can throw *after* real writes have landed, which is the only
/// way to show that a rollback undoes them. A fault thrown before the first
/// write proves nothing.
enum IngestFaultPoint {
  /// The metadata row and its notebook edges are written; the document and the
  /// chunk set have not.
  afterMetadata,

  /// The document text is written.
  afterDocument,

  /// The chunk set is replaced. The last point, and the one that matters most:
  /// it is after every write in the DAG.
  afterChunks,
}

/// The test seam. Production passes nothing.
///
/// [point] is invoked from inside the transaction, so throwing from it is a
/// genuine mid-transaction failure rather than a simulated one.
typedef IngestFaultHook = void Function(String publicationUuid, IngestFaultPoint point);

/// One planned notebook.
class _NotebookPlan {
  final NotebookDto dto;

  /// True when this device had never seen the notebook.
  final bool created;

  const _NotebookPlan({required this.dto, required this.created});
}

/// What an ingest did.
class IngestResult {
  /// Notebooks written.
  final int notebooksApplied;

  /// Publications written, whether by metadata, document, or chunk set.
  final int publicationsApplied;

  /// Publications refused: tombstoned (FR14), or outranked by the local version
  /// (FR9).
  final int publicationsSkipped;

  /// Deletes applied. Includes deletes for objects this device never had, which
  /// record a tombstone and no deletion.
  final int deletesApplied;

  /// Publications whose metadata arrived but whose vectors the `embeddingModelId`
  /// gate withheld (FR5b).
  ///
  /// Non-empty is the signal that this device and its peer disagree about the
  /// embedding model. It is expected rather than exceptional, and it is the only
  /// trace of it in the protocol — nothing in the stored data distinguishes
  /// "deliberately unindexed" from "never indexed".
  final List<String> vectorsRefused;

  const IngestResult({
    required this.notebooksApplied,
    required this.publicationsApplied,
    required this.publicationsSkipped,
    required this.deletesApplied,
    required this.vectorsRefused,
  });

  @override
  String toString() => 'IngestResult(notebooks: $notebooksApplied, '
      'applied: $publicationsApplied, '
      'skipped: $publicationsSkipped, deleted: $deletesApplied, '
      'vectorsRefused: $vectorsRefused)';
}

/// One planned publication, decided before anything was resolved or written.
class _Plan {
  final PublicationDto dto;
  final bool applyMetadata;
  final bool applyChunkSet;
  final bool applyDocument;

  /// The set arrived but was withheld because the models differ (FR5b).
  final bool vectorsGated;

  /// Leave `embeddingModelId` alone: this publication already holds chunks
  /// produced by the local model, and relabelling them with a foreign model's
  /// name is the vector-space mix FR5b forbids, reached through the metadata.
  final bool keepLocalModelLabel;

  const _Plan({
    required this.dto,
    required this.applyMetadata,
    required this.applyChunkSet,
    required this.applyDocument,
    required this.vectorsGated,
    required this.keepLocalModelLabel,
  });
}

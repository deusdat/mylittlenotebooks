import 'dart:convert';

import 'package:mylittlenotebooks/data/objectbox/ob_ai_config.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_chunk.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_document.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_note.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_note_chunk.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_note_document.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_notebook.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_peer_watermark.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_publication.dart';
import 'package:mylittlenotebooks/data/secrets/flutter_secure_token_store.dart';
import 'package:mylittlenotebooks/data/secrets/token_store.dart';
import 'package:mylittlenotebooks/data/sync/device_id.dart';
import 'package:mylittlenotebooks/data/sync/sync_codec.dart';
import 'package:mylittlenotebooks/data/sync/sync_payload.dart';
import 'package:mylittlenotebooks/data/sync/sync_tombstones.dart';
import 'package:mylittlenotebooks/objectbox.g.dart';

/// Builds the delta to push to one peer, and remembers what that peer has
/// acknowledged (spec FR11).
///
/// **There is no dirty flag.** A record is in the delta exactly when its version
/// has moved past what that peer last acknowledged, so dirty-tracking falls out
/// of the same data last-write-wins already needs. A separate flag would have to
/// be kept in step with the version by hand at every write path, and the two
/// would drift.
///
/// **The watermark is per record and per axis** — see `ObPeerWatermark` for why a
/// single number per peer loses re-indexes silently.
///
/// **It advances only on acknowledgement** (plan R7). An interrupted push that
/// advanced it would skip those records on the next attempt and lose them
/// permanently — the one failure mode idempotency does not cover, because nothing
/// throws on the retry; it just quietly sends less.
///
/// **A peer with no rows means "everything", not "nothing".** Named explicitly
/// rather than defaulted to zero, because "never pushed to" and "fully up to
/// date" are opposite situations that a zero default would conflate.
class PushSender {
  PushSender({
    required Store store,
    String? deviceId,
    TombstoneStore? tombstones,
    TokenStore? tokens,
  })  : _store = store,
        _deviceId = deviceId ?? resolveDeviceId(store),
        _tombstones = tombstones ?? TombstoneStore(store),
        _tokens = tokens ?? FlutterSecureTokenStore();

  final Store _store;
  final String _deviceId;
  final TombstoneStore _tombstones;

  /// The secret store used to fill [AiConfigDto.token] for shared tuples.
  ///
  /// It is only read for the handful of shared tuples a given push selects, and
  /// never during selection itself (plan I3). Tests inject a fake.
  final TokenStore _tokens;

  /// What [peerDeviceId] has acknowledged for [recordUuid], or null when it has
  /// never been sent.
  SentCounters? sentTo(String peerDeviceId, String recordUuid) {
    final row = _watermarkRow(peerDeviceId, recordUuid);
    if (row == null) return null;
    return SentCounters(
      metadata: row.metadataCounter,
      chunkSet: row.chunkSetCounter,
      document: row.documentCounter,
    );
  }

  /// Every record this peer has been sent something for.
  int recordsSentTo(String peerDeviceId) {
    final query = _watermarks
        .query(ObPeerWatermark_.peerDeviceId.equals(peerDeviceId))
        .build();
    try {
      return query.count();
    } finally {
      query.close();
    }
  }

  /// Records what [peerDeviceId] confirmed, replacing whatever was recorded.
  ///
  /// **Only call this after the peer has confirmed.** See the class note. Rows
  /// move forward only: a late acknowledgement from an interrupted attempt must
  /// not undo a newer one.
  void acknowledge(String peerDeviceId, SyncPayload payload) {
    for (final notebook in payload.notebooks) {
      _write(
        peerDeviceId,
        notebook.uuid,
        SentCounters(
          metadata: notebook.version.counter,
          chunkSet: 0,
          document: 0,
        ),
        _watermarkRow(peerDeviceId, notebook.uuid),
      );
    }
    for (final publication in payload.publications) {
      final existing = _watermarkRow(peerDeviceId, publication.uuid);
      final counters = SentCounters(
        metadata: publication.version.counter,
        chunkSet: publication.chunkSetVersion.counter,
        document: publication.document?.version.counter ?? 0,
      );
      _write(peerDeviceId, publication.uuid, counters, existing);
    }
    for (final delete in payload.deletes) {
      final existing = _watermarkRow(peerDeviceId, delete.uuid);
      _write(
        peerDeviceId,
        delete.uuid,
        SentCounters(
          metadata: delete.version.counter,
          chunkSet: 0,
          document: 0,
        ),
        existing,
      );
    }
    for (final config in payload.aiConfigs) {
      // Including an unshared record: recording its version is what stops the
      // "remove this tuple" instruction being re-sent on every later push.
      final existing = _watermarkRow(peerDeviceId, config.uuid);
      _write(
        peerDeviceId,
        config.uuid,
        SentCounters(
          metadata: config.version.counter,
          chunkSet: 0,
          document: 0,
        ),
        existing,
      );
    }
    for (final note in payload.notes) {
      final existing = _watermarkRow(peerDeviceId, note.uuid);
      _write(
        peerDeviceId,
        note.uuid,
        SentCounters(
          metadata: note.version.counter,
          chunkSet: note.chunkSetVersion.counter,
          document: note.document?.version.counter ?? 0,
        ),
        existing,
      );
    }
  }

  /// Forgets everything about [peerDeviceId].
  ///
  /// Needed whenever a peer is removed: its rows would otherwise keep a
  /// reintroduced peer from receiving a first push.
  int forgetPeer(String peerDeviceId) {
    final query = _watermarks
        .query(ObPeerWatermark_.peerDeviceId.equals(peerDeviceId))
        .build();
    try {
      return query.remove();
    } finally {
      query.close();
    }
  }

  /// Everything [peerDeviceId] has not acknowledged (FR11).
  ///
  /// Selects metadata, document text, and the chunk set by their **independent**
  /// versions (FR5a): a publication whose title changed transfers its metadata
  /// and no chunks, and only a re-index transfers the set. Selecting the set with
  /// the metadata version is the bug that makes renaming something cost a full
  /// corpus transfer.
  ///
  /// A publication is included when *any* of its three axes moved, since the
  /// record has to travel to carry whichever one did.
  ///
  /// **AI configurations (settings-for-ai FR12, FR13).** [tokens] supplies the
  /// secrets for the shared tuples this selection includes; [push] preloads it.
  /// A shared tuple is included when its version moved. An **unshared** tuple is
  /// included **only when this peer already has a watermark row for it** — that
  /// is, it was shared with this peer before and the record says "remove your
  /// copy". A tuple that was never shared must not appear at all, or every
  /// private configuration would be broadcast as a removal on the first push.
  SyncPayload selectDelta(
    String peerDeviceId, {
    Map<String, String> tokens = const {},
  }) {
    // Notebooks first: they are the roots of the DAG (FR7).
    final notebooks = <NotebookDto>[];
    final notebookQuery = _notebooks.query().build();
    try {
      for (final notebook in notebookQuery.find()) {
        final sent = sentTo(peerDeviceId, notebook.uuid);
        if (!_moved(sent?.metadata, notebook.versionCounter)) continue;
        notebooks.add(NotebookDto(
          uuid: notebook.uuid,
          title: notebook.title,
          version: VersionDto(counter: notebook.versionCounter, deviceId: _deviceId),
        ));
      }
    } finally {
      notebookQuery.close();
    }

    final publications = <PublicationDto>[];
    final query = _publications.query().build();
    try {
      for (final publication in query.find()) {
        final sent = sentTo(peerDeviceId, publication.uuid);
        final document = _documentFor(publication.id);

        final metadataMoved = _moved(
          sent?.metadata,
          publication.versionCounter,
        );
        final setMoved = _moved(sent?.chunkSet, publication.chunkSetVersion);
        final documentMoved = _moved(
          sent?.document,
          document?.versionCounter ?? 0,
        );
        if (!metadataMoved && !setMoved && !documentMoved) continue;

        publications.add(_toDto(
          publication,
          document: document,
          includeMetadata: metadataMoved,
          includeChunkSet: setMoved,
          includeDocument: documentMoved,
        ));
      }
    } finally {
      query.close();
    }

    final deletes = <DeleteDto>[];
    for (final tombstone in _tombstones.all()) {
      final sent = sentTo(peerDeviceId, tombstone.uuid);
      if (!_moved(sent?.metadata, tombstone.versionCounter)) continue;
      deletes.add(DeleteDto(
        uuid: tombstone.uuid,
        version: VersionDto(
          counter: tombstone.versionCounter,
          deviceId: _deviceId,
        ),
      ));
    }

    // AI configurations (settings-for-ai FR12, FR13).
    final aiConfigs = <AiConfigDto>[];
    final configQuery = _aiConfigs.query().build();
    try {
      for (final config in configQuery.find()) {
        final sent = sentTo(peerDeviceId, config.uuid);
        if (config.shared) {
          if (!_moved(sent?.metadata, config.versionCounter)) continue;
          aiConfigs.add(AiConfigDto(
            uuid: config.uuid,
            label: config.label,
            endpoint: config.endpoint,
            shared: true,
            token: tokens[config.uuid],
            version: VersionDto(
              counter: config.versionCounter,
              deviceId: _deviceId,
            ),
          ));
        } else {
          // Unshare. Only meaningful if this peer was told about the tuple
          // before; a tuple that was never shared must never travel.
          if (sent == null || !_moved(sent.metadata, config.versionCounter)) {
            continue;
          }
          aiConfigs.add(AiConfigDto(
            uuid: config.uuid,
            label: config.label,
            endpoint: config.endpoint,
            shared: false,
            version: VersionDto(
              counter: config.versionCounter,
              deviceId: _deviceId,
            ),
          ));
        }
      }
    } finally {
      configQuery.close();
    }

    // Notes (spec FR24). Three independent axes exactly as a publication, so a
    // retitle transfers metadata and no chunks.
    final notes = <NoteDto>[];
    final noteQuery = _notes.query().build();
    try {
      for (final note in noteQuery.find()) {
        final sent = sentTo(peerDeviceId, note.uuid);
        final document = _noteDocumentFor(note.id);

        final metadataMoved = _moved(sent?.metadata, note.versionCounter);
        final setMoved = _moved(sent?.chunkSet, note.chunkSetVersion);
        final documentMoved =
            _moved(sent?.document, document?.versionCounter ?? 0);
        if (!metadataMoved && !setMoved && !documentMoved) continue;

        notes.add(_toNoteDto(
          note,
          document: document,
          includeMetadata: metadataMoved,
          includeChunkSet: setMoved,
          includeDocument: documentMoved,
        ));
      }
    } finally {
      noteQuery.close();
    }

    return SyncPayload(
      notebooks: notebooks,
      publications: publications,
      deletes: deletes,
      aiConfigs: aiConfigs,
      notes: notes,
    );
  }

  /// The uuids of shared configurations whose version moved for [peerDeviceId].
  ///
  /// Selection is synchronous; the token read is not. This lets [push] resolve
  /// only the secrets it actually needs, in one batch, before it selects.
  Iterable<String> _sharedConfigUuidsMovedFor(String peerDeviceId) sync* {
    final query = _aiConfigs.query().build();
    try {
      for (final config in query.find()) {
        if (!config.shared) continue;
        final sent = sentTo(peerDeviceId, config.uuid);
        if (_moved(sent?.metadata, config.versionCounter)) yield config.uuid;
      }
    } finally {
      query.close();
    }
  }

  /// Selects the delta, hands it to [deliver], and records the acknowledgement
  /// **only if the peer confirms**.
  ///
  /// [deliver] returning normally *is* the confirmation. A throw propagates and
  /// nothing is recorded, so the next attempt re-selects the identical range
  /// (AC5, plan R7).
  Future<void> push(
    String peerDeviceId,
    Future<void> Function(String encoded) deliver,
  ) async {
    // Resolve the shared tuples' secrets first, then select synchronously.
    final tokens = await _tokens.readMany(_sharedConfigUuidsMovedFor(peerDeviceId));
    final payload = selectDelta(peerDeviceId, tokens: tokens);
    final encoded = encodePayload(payload);
    await deliver(encoded);
    // Only now. Everything above this line can fail and be retried.
    acknowledge(peerDeviceId, payload);
  }

  /// Whether [now] has moved past what the peer was last sent ([last]).
  ///
  /// A null [last] means the peer has never been sent this record, so everything
  /// is outstanding.
  bool _moved(int? last, int now) => last == null || now > last;

  PublicationDto _toDto(
    ObPublication publication, {
    required ObDocument? document,
    required bool includeMetadata,
    required bool includeChunkSet,
    required bool includeDocument,
  }) {
    // Chunk uuids are derived from `(publicationUuid, chunkIndex)`, not read back
    // and hoped over: re-deriving is what makes a re-push byte-identical to the
    // first (AC5) even after a partial transfer.
    final chunks = includeChunkSet ? _chunksFor(publication) : const <ChunkDto>[];

    return PublicationDto(
      uuid: publication.uuid,
      title: publication.title,
      byteSize: publication.byteSize,
      embeddingModelId: publication.embeddingModelId,
      // Always "how many chunks are in *this* payload", never what the
      // publication holds locally. The two differ on a metadata-only push, and
      // conflating them makes a partial push look like the truncation FR5a-bis
      // exists to catch — so the receiver refuses a payload that was fine.
      declaredChunkCount: chunks.length,
      chunksIncluded: includeChunkSet,
      version: VersionDto(
        counter: publication.versionCounter,
        deviceId: _deviceId,
      ),
      chunkSetVersion: VersionDto(
        counter: publication.chunkSetVersion,
        deviceId: _deviceId,
      ),
      // Sorted so two selections of the same state produce identical bytes.
      notebookUuids: publication.notebooks.map((n) => n.uuid).toList()..sort(),
      document: includeDocument && document != null
          ? DocumentDto(
              uuid: document.uuid,
              publicationUuid: publication.uuid,
              markdown: document.markdown,
              version: VersionDto(
                counter: document.versionCounter,
                deviceId: _deviceId,
              ),
            )
          : null,
      chunks: chunks,
    );
  }

  List<ChunkDto> _chunksFor(ObPublication publication) {
    final query = _chunks
        .query(ObChunk_.publicationId.equals(publication.id))
        .build();
    try {
      final rows = query.find()
        ..sort((a, b) => a.chunkIndex.compareTo(b.chunkIndex));
      return [
        for (final row in rows)
          ChunkDto(
            uuid: row.uuid,
            chunkIndex: row.chunkIndex,
            content: row.content,
            tokenCount: row.tokenCount,
            publicationUuid: publication.uuid,
            embeddingBase64: encodeVector(row.embedding),
            // The set's version, not a per-chunk one. The set is replaced
            // wholesale under this single version (FR5a), so a per-chunk counter
            // would be a second authority deciding something the set version has
            // already decided — and two authorities can disagree.
            version: VersionDto(
                counter: publication.chunkSetVersion, deviceId: _deviceId),
          ),
      ];
    } finally {
      query.close();
    }
  }

  ObDocument? _documentFor(int publicationId) {
    final query = _documents
        .query(ObDocument_.publicationId.equals(publicationId))
        .build();
    try {
      return query.findFirst();
    } finally {
      query.close();
    }
  }

  /// Builds a note record for the selected axes (spec FR24).
  NoteDto _toNoteDto(
    ObNote note, {
    required ObNoteDocument? document,
    required bool includeMetadata,
    required bool includeChunkSet,
    required bool includeDocument,
  }) {
    final chunks =
        includeChunkSet ? _noteChunksFor(note) : const <NoteChunkDto>[];

    return NoteDto(
      uuid: note.uuid,
      title: note.title,
      createdAt: note.createdAt,
      updatedAt: note.updatedAt,
      embeddingModelId: note.embeddingModelId,
      // Always "how many chunks are in *this* payload", never local state.
      declaredChunkCount: chunks.length,
      chunksIncluded: includeChunkSet,
      version: VersionDto(
        counter: note.versionCounter,
        deviceId: _deviceId,
      ),
      chunkSetVersion: VersionDto(
        counter: note.chunkSetVersion,
        deviceId: _deviceId,
      ),
      notebookUuids: note.notebooks.map((n) => n.uuid).toList()..sort(),
      document: includeDocument && document != null
          ? NoteDocumentDto(
              uuid: document.uuid,
              noteUuid: note.uuid,
              markdown: document.markdown,
              version: VersionDto(
                counter: document.versionCounter,
                deviceId: _deviceId,
              ),
            )
          : null,
      chunks: chunks,
    );
  }

  List<NoteChunkDto> _noteChunksFor(ObNote note) {
    final query =
        _noteChunks.query(ObNoteChunk_.noteId.equals(note.id)).build();
    try {
      final rows = query.find()
        ..sort((a, b) => a.chunkIndex.compareTo(b.chunkIndex));
      return [
        for (final row in rows)
          NoteChunkDto(
            uuid: row.uuid,
            chunkIndex: row.chunkIndex,
            content: row.content,
            tokenCount: row.tokenCount,
            noteUuid: note.uuid,
            embeddingBase64: encodeVector(row.embedding),
            // The set's version, not a per-chunk one (the set is replaced
            // wholesale under this single version).
            version: VersionDto(
                counter: note.chunkSetVersion, deviceId: _deviceId),
          ),
      ];
    } finally {
      query.close();
    }
  }

  ObNoteDocument? _noteDocumentFor(int noteId) {
    final query =
        _noteDocuments.query(ObNoteDocument_.noteId.equals(noteId)).build();
    try {
      return query.findFirst();
    } finally {
      query.close();
    }
  }

  void _write(
    String peerDeviceId,
    String recordUuid,
    SentCounters counters,
    ObPeerWatermark? existing,
  ) {
    if (existing != null) {
      // Forward only. See `acknowledge`.
      if (counters.metadata < existing.metadataCounter &&
          counters.chunkSet < existing.chunkSetCounter &&
          counters.document < existing.documentCounter) {
        return;
      }
      existing.metadataCounter =
          counters.metadata > existing.metadataCounter
              ? counters.metadata
              : existing.metadataCounter;
      existing.chunkSetCounter = counters.chunkSet > existing.chunkSetCounter
          ? counters.chunkSet
          : existing.chunkSetCounter;
      existing.documentCounter = counters.document > existing.documentCounter
          ? counters.document
          : existing.documentCounter;
      _watermarks.put(existing);
      return;
    }
    _watermarks.put(ObPeerWatermark(
      peerDeviceId: peerDeviceId,
      recordUuid: recordUuid,
      metadataCounter: counters.metadata,
      chunkSetCounter: counters.chunkSet,
      documentCounter: counters.document,
    ));
  }

  ObPeerWatermark? _watermarkRow(String peerDeviceId, String recordUuid) {
    final query = _watermarks
        .query(ObPeerWatermark_.recordKey
            .equals(ObPeerWatermark.keyFor(peerDeviceId, recordUuid)))
        .build();
    try {
      return query.findFirst();
    } finally {
      query.close();
    }
  }

  Box<ObPublication> get _publications => _store.box<ObPublication>();
  Box<ObDocument> get _documents => _store.box<ObDocument>();
  Box<ObChunk> get _chunks => _store.box<ObChunk>();
  Box<ObNotebook> get _notebooks => _store.box<ObNotebook>();
  Box<ObAiConfig> get _aiConfigs => _store.box<ObAiConfig>();
  Box<ObPeerWatermark> get _watermarks => _store.box<ObPeerWatermark>();
  Box<ObNote> get _notes => _store.box<ObNote>();
  Box<ObNoteChunk> get _noteChunks => _store.box<ObNoteChunk>();
  Box<ObNoteDocument> get _noteDocuments => _store.box<ObNoteDocument>();
}

/// The three independent versions of one record, as last sent to a peer.
class SentCounters {
  final int metadata;
  final int chunkSet;
  final int document;

  const SentCounters({
    required this.metadata,
    required this.chunkSet,
    required this.document,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SentCounters &&
          other.metadata == metadata &&
          other.chunkSet == chunkSet &&
          other.document == document;

  @override
  int get hashCode => Object.hash(metadata, chunkSet, document);

  @override
  String toString() =>
      'SentCounters(metadata: $metadata, chunkSet: $chunkSet, document: $document)';
}

/// Bytes a payload occupies on the wire, for the delta-size measurement (T17).
///
/// Measured rather than estimated: the Revision 2 record quotes a first-push cost
/// and a number nobody measured is a number nobody should rely on.
int encodedLengthOf(SyncPayload payload) =>
    utf8.encode(encodePayload(payload)).length;

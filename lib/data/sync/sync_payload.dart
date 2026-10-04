import 'package:mylittlenotebooks/data/sync/sync_version.dart';

/// Transport DTOs (spec FR4).
///
/// **These are the wire format, and they are deliberately not the entity
/// classes.** An entity carries an int64 storage id that is meaningless outside
/// this device; these carry uuids instead. Keeping them separate means a
/// property rename in the store cannot silently change the protocol (plan D10).
///
/// Every reference here is a **uuid**. No int storage id appears anywhere in
/// this file, and AC3 asserts that by encoding a payload and checking it
/// against known local ids.
///
/// There is **no `isDeleted` flag** and **no tombstone field** (FR13): a delete
/// is a separate record type, not a flag on an upsert, and tombstones are local
/// state that never travels.

/// A record's position in the last-write-wins order.
class VersionDto {
  final int counter;
  final String deviceId;

  const VersionDto({required this.counter, required this.deviceId});

  factory VersionDto.fromDomain(SyncVersion version) =>
      VersionDto(counter: version.counter, deviceId: version.deviceId);

  SyncVersion toDomain() => (counter: counter, deviceId: deviceId);

  Map<String, Object?> toJson() => {'c': counter, 'd': deviceId};

  /// Returns null when the shape is wrong, so a malformed record is refused
  /// rather than half-populated.
  static VersionDto? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final counter = raw['c'];
    final deviceId = raw['d'];
    if (counter is! int || deviceId is! String) return null;
    return VersionDto(counter: counter, deviceId: deviceId);
  }
}

/// A notebook as it travels.
///
/// **Notebooks are records, not just references.** `PublicationDto.notebookUuids`
/// names them, and before this record existed the receiver created an untitled
/// row for each — a notebook in the sidebar with an empty title, indistinguishable
/// from a bug. The title is user data, so it travels.
///
/// It also makes the DAG honest: a notebook is a *root*, applied before anything
/// that references it, rather than a row conjured into existence by a reference.
class NotebookDto {
  final String uuid;
  final String title;
  final VersionDto version;

  const NotebookDto({
    required this.uuid,
    required this.title,
    required this.version,
  });

  Map<String, Object?> toJson() => {'uuid': uuid, 'title': title, 'v': version.toJson()};

  static NotebookDto? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final version = VersionDto.fromJson(raw['v']);
    final uuid = raw['uuid'];
    final title = raw['title'];
    if (version == null || uuid is! String || title is! String) return null;
    return NotebookDto(uuid: uuid, title: title, version: version);
  }
}

/// One chunk as it travels.
///
/// [publicationUuid] is the portable reference; the receiving device resolves
/// it to its own local int. The vector is base64 over raw float32 bytes (FR5c).
class ChunkDto {
  final String uuid;
  final int chunkIndex;
  final String content;
  final int tokenCount;

  /// The parent, as a uuid. Never a storage id.
  final String publicationUuid;

  /// Base64 of the `Float32List`'s bytes — 1,368 characters for 256 dimensions.
  final String embeddingBase64;

  final VersionDto version;

  const ChunkDto({
    required this.uuid,
    required this.chunkIndex,
    required this.content,
    required this.tokenCount,
    required this.publicationUuid,
    required this.embeddingBase64,
    required this.version,
  });

  Map<String, Object?> toJson() => {
        'uuid': uuid,
        'i': chunkIndex,
        'c': content,
        't': tokenCount,
        'p': publicationUuid,
        'e': embeddingBase64,
        'v': version.toJson(),
      };

  static ChunkDto? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final version = VersionDto.fromJson(raw['v']);
    final uuid = raw['uuid'];
    final chunkIndex = raw['i'];
    final content = raw['c'];
    final tokenCount = raw['t'];
    final publicationUuid = raw['p'];
    final embedding = raw['e'];
    if (version == null ||
        uuid is! String ||
        chunkIndex is! int ||
        content is! String ||
        tokenCount is! int ||
        publicationUuid is! String ||
        embedding is! String) {
      return null;
    }
    return ChunkDto(
      uuid: uuid,
      chunkIndex: chunkIndex,
      content: content,
      tokenCount: tokenCount,
      publicationUuid: publicationUuid,
      embeddingBase64: embedding,
      version: version,
    );
  }
}

/// A publication's document text as it travels.
class DocumentDto {
  final String uuid;
  final String publicationUuid;
  final String markdown;
  final VersionDto version;

  const DocumentDto({
    required this.uuid,
    required this.publicationUuid,
    required this.markdown,
    required this.version,
  });

  Map<String, Object?> toJson() => {
        'uuid': uuid,
        'p': publicationUuid,
        'm': markdown,
        'v': version.toJson(),
      };

  static DocumentDto? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final version = VersionDto.fromJson(raw['v']);
    final uuid = raw['uuid'];
    final publicationUuid = raw['p'];
    final markdown = raw['m'];
    if (version == null ||
        uuid is! String ||
        publicationUuid is! String ||
        markdown is! String) {
      return null;
    }
    return DocumentDto(
      uuid: uuid,
      publicationUuid: publicationUuid,
      markdown: markdown,
      version: version,
    );
  }
}

/// A publication's metadata, plus its chunk set.
///
/// [chunkSetVersion] is tracked **independently** of [version] (FR5a). Retitling
/// a publication bumps only [version] and transfers no chunks; a re-index bumps
/// [chunkSetVersion] and sends the set. Without the split, renaming something
/// would cost a full corpus transfer.
///
/// [declaredChunkCount] is the sender's declared size of [chunks], carried
/// *outside* the list (FR5a-bis). It is what makes truncation detectable: thirty
/// contiguous chunks are otherwise indistinguishable from a legitimately
/// thirty-chunk publication. It is a **check, never a repair** — a mismatch
/// refuses the whole payload rather than pruning toward a number.
class PublicationDto {
  final String uuid;
  final String title;
  final int byteSize;
  final String embeddingModelId;

  /// The declared chunk count. See the class note.
  final int declaredChunkCount;

  /// Whether this payload carries the chunk set at all.
  ///
  /// **Without this, a metadata-only push silently erases the receiver's chunks.**
  /// FR5a says a retitle sends metadata and no chunks, which leaves the receiver
  /// unable to tell three states apart from `chunks: []` alone:
  ///
  /// | State | Meaning |
  /// |---|---|
  /// | no chunks, declared 0 | the publication genuinely has no chunks |
  /// | no chunks, declared 0, set version unchanged | nothing to send — the receiver already has them |
  /// | no chunks, declared 0, set version advanced | the set shrank to nothing |
  ///
  /// The receiver acts on "the set version advanced", so it cannot choose between
  /// the last two: it applies an empty set and **wipes every chunk it held**,
  /// reporting `chunkCount == 0` as though that were the truth. Nothing throws
  /// and the document is still there.
  ///
  /// So the sender states which of the three it means. `declaredChunkCount` keeps
  /// its single meaning — *how many chunks are in this payload* — and this field
  /// says whether a set was selected for transfer at all.
  final bool chunksIncluded;

  final VersionDto version;
  final VersionDto chunkSetVersion;

  /// The notebook uuids this publication is attached to.
  final List<String> notebookUuids;

  final DocumentDto? document;
  final List<ChunkDto> chunks;

  const PublicationDto({
    required this.uuid,
    required this.title,
    required this.byteSize,
    required this.embeddingModelId,
    required this.declaredChunkCount,
    required this.version,
    required this.chunkSetVersion,
    this.chunksIncluded = true,
    required this.notebookUuids,
    this.document,
    this.chunks = const [],
  });

  Map<String, Object?> toJson() => {
        'uuid': uuid,
        'title': title,
        'size': byteSize,
        'model': embeddingModelId,
        'declaredChunks': declaredChunkCount,
        'chunksIncluded': chunksIncluded,
        'v': version.toJson(),
        'csv': chunkSetVersion.toJson(),
        'notebooks': notebookUuids,
        'document': document?.toJson(),
        'chunks': chunks.map((c) => c.toJson()).toList(),
      };

  static PublicationDto? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final version = VersionDto.fromJson(raw['v']);
    final chunkSetVersion = VersionDto.fromJson(raw['csv']);
    final uuid = raw['uuid'];
    final title = raw['title'];
    final byteSize = raw['size'];
    final model = raw['embeddingModelId'] ?? raw['model'];
    final declared = raw['declaredChunks'];
    // Absent means `true`: a payload that predates this field carried a set
    // whenever it listed chunks, and defaulting the other way would make old
    // payloads look like metadata-only pushes and be ignored.
    final chunksIncluded = raw['chunksIncluded'] ?? true;
    final notebooks = raw['notebooks'];
    if (version == null ||
        chunkSetVersion == null ||
        uuid is! String ||
        title is! String ||
        byteSize is! int ||
        model is! String ||
        declared is! int ||
        chunksIncluded is! bool ||
        notebooks is! List) {
      return null;
    }
    final rawChunks = raw['chunks'];
    final chunks = <ChunkDto>[];
    if (rawChunks is List) {
      for (final entry in rawChunks) {
        final parsed = ChunkDto.fromJson(entry);
        if (parsed == null) return null; // total: never half-populated
        chunks.add(parsed);
      }
    } else if (rawChunks != null) {
      return null;
    }
    return PublicationDto(
      uuid: uuid,
      title: title,
      byteSize: byteSize,
      embeddingModelId: model,
      declaredChunkCount: declared,
      version: version,
      chunkSetVersion: chunkSetVersion,
      chunksIncluded: chunksIncluded,
      notebookUuids: notebooks.whereType<String>().toList(),
      document: DocumentDto.fromJson(raw['document']),
      chunks: chunks,
    );
  }
}

/// One AI endpoint configuration as it travels (settings-for-ai FR11).
///
/// [token] is present **only when [shared] is true**. An unshared record is not
/// an upsert at all: it tells the receiver to remove its copy of the tuple
/// (FR13), which is why it still carries a uuid and a version but no secret.
///
/// A **delete** is not expressed here; it uses the existing [DeleteDto] like
/// every other record type.
class AiConfigDto {
  final String uuid;
  final String label;
  final String endpoint;
  final bool shared;

  /// The bearer token, or null. Never logged; see [SyncPayloadException].
  final String? token;

  final VersionDto version;

  const AiConfigDto({
    required this.uuid,
    required this.label,
    required this.endpoint,
    required this.shared,
    required this.version,
    this.token,
  });

  Map<String, Object?> toJson() => {
        'uuid': uuid,
        'label': label,
        'endpoint': endpoint,
        'shared': shared,
        if (token != null) 'token': token,
        'v': version.toJson(),
      };

  static AiConfigDto? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final version = VersionDto.fromJson(raw['v']);
    final uuid = raw['uuid'];
    final label = raw['label'];
    final endpoint = raw['endpoint'];
    final shared = raw['shared'];
    final token = raw['token'];
    if (version == null ||
        uuid is! String ||
        label is! String ||
        endpoint is! String ||
        shared is! bool ||
        (token != null && token is! String)) {
      return null;
    }
    return AiConfigDto(
      uuid: uuid,
      label: label,
      endpoint: endpoint,
      shared: shared,
      version: version,
      token: token as String?,
    );
  }
}

/// A delete, as it travels.///
/// Just a uuid and a version. It carries nothing about the deleted object's
/// children, because the receiver derives all of them **locally** from its own
/// int: chunks by `publicationId`, the document by its own column, association
/// edges by the publication's uuid. Nothing else needs to travel.
class DeleteDto {
  final String uuid;
  final VersionDto version;

  const DeleteDto({required this.uuid, required this.version});

  Map<String, Object?> toJson() => {'uuid': uuid, 'v': version.toJson()};

  static DeleteDto? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final version = VersionDto.fromJson(raw['v']);
    final uuid = raw['uuid'];
    if (version == null || uuid is! String) return null;
    return DeleteDto(uuid: uuid, version: version);
  }
}

/// A complete transfer between two devices.
class SyncPayload {
  /// Notebooks first: they are the roots of the DAG (FR7).
  final List<NotebookDto> notebooks;
  final List<PublicationDto> publications;
  final List<DeleteDto> deletes;

  /// Shared AI configurations (settings-for-ai FR11). An unshared configuration
  /// is never a plain upsert; see [AiConfigDto].
  final List<AiConfigDto> aiConfigs;

  const SyncPayload({
    this.notebooks = const [],
    required this.publications,
    required this.deletes,
    this.aiConfigs = const [],
  });

  Map<String, Object?> toJson() => {
        'notebooks': notebooks.map((n) => n.toJson()).toList(),
        'publications': publications.map((p) => p.toJson()).toList(),
        'deletes': deletes.map((d) => d.toJson()).toList(),
        'aiConfigs': aiConfigs.map((c) => c.toJson()).toList(),
      };

  /// Returns null if anything in the payload is malformed. Total by
  /// construction: a partially-decoded payload is never handed to ingest.
  static SyncPayload? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final rawNotebooks = raw['notebooks'] ?? const [];
    final rawPublications = raw['publications'];
    final rawDeletes = raw['deletes'];
    // Absent means old payloads predate this field; they carry no configs.
    final rawAiConfigs = raw['aiConfigs'] ?? const [];
    if (rawNotebooks is! List ||
        rawPublications is! List ||
        rawDeletes is! List ||
        rawAiConfigs is! List) {
      return null;
    }

    final notebooks = <NotebookDto>[];
    for (final entry in rawNotebooks) {
      final parsed = NotebookDto.fromJson(entry);
      if (parsed == null) return null;
      notebooks.add(parsed);
    }

    final publications = <PublicationDto>[];
    for (final entry in rawPublications) {
      final parsed = PublicationDto.fromJson(entry);
      if (parsed == null) return null;
      publications.add(parsed);
    }
    final deletes = <DeleteDto>[];
    for (final entry in rawDeletes) {
      final parsed = DeleteDto.fromJson(entry);
      if (parsed == null) return null;
      deletes.add(parsed);
    }
    final aiConfigs = <AiConfigDto>[];
    for (final entry in rawAiConfigs) {
      final parsed = AiConfigDto.fromJson(entry);
      if (parsed == null) return null;
      aiConfigs.add(parsed);
    }
    return SyncPayload(
      notebooks: notebooks,
      publications: publications,
      deletes: deletes,
      aiConfigs: aiConfigs,
    );
  }
}

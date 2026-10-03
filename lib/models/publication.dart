/// An imported source document (spec FR2).
///
/// A pure domain value: no `package:flutter`, no `package:objectbox`. The
/// storage entity is `ObPublication` and the conversion lives in
/// `lib/domain_mapping.dart` (spec NFR5, C3).
///
/// There is no `filePath`. On iOS a picked file's path is not durably readable
/// and on Android a content URI's permission grant does not survive a relaunch,
/// so the document text is the record of truth (spec FR3, FR4).
class Publication {
  /// Application-level identity. Stable, generated at creation, never
  /// reassigned. The storage layer's int id must not appear here (spec FR5).
  final String uuid;

  final String title;

  /// The complete source document. Never loaded by a list or search path
  /// (spec NFR6) — it is read only for preview and re-chunking.
  final String sourceMarkdown;

  /// Byte length of [sourceMarkdown], not of a file on disk (spec D8).
  final int byteSize;

  final DateTime importedAt;

  /// Names the model *and configuration* that produced this publication's
  /// vectors. Two vectors are only comparable when these match; a mismatch
  /// silently mixes vector spaces and returns confident nonsense (spec FR6).
  final String embeddingModelId;

  /// Denormalised count, so a publication list renders without loading chunks
  /// (spec FR9).
  final int chunkCount;

  const Publication({
    required this.uuid,
    required this.title,
    required this.sourceMarkdown,
    required this.byteSize,
    required this.importedAt,
    required this.embeddingModelId,
    this.chunkCount = 0,
  });

  Publication copyWith({String? title, int? chunkCount}) => Publication(
        uuid: uuid,
        title: title ?? this.title,
        sourceMarkdown: sourceMarkdown,
        byteSize: byteSize,
        importedAt: importedAt,
        embeddingModelId: embeddingModelId,
        chunkCount: chunkCount ?? this.chunkCount,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Publication &&
          other.uuid == uuid &&
          other.title == title &&
          other.sourceMarkdown == sourceMarkdown &&
          other.byteSize == byteSize &&
          other.importedAt == importedAt &&
          other.embeddingModelId == embeddingModelId &&
          other.chunkCount == chunkCount;

  @override
  int get hashCode => Object.hash(
        uuid,
        title,
        sourceMarkdown,
        byteSize,
        importedAt,
        embeddingModelId,
        chunkCount,
      );

  @override
  String toString() => 'Publication($uuid, $title, $chunkCount chunks)';
}

/// A publication's metadata, without its source text.
///
/// Returned by every list and search path. ObjectBox loads whole objects, so a
/// repository that returned the full [Publication] from a list would read every
/// document in the store — the reason the document text lives in its own row
/// (spec NFR6, spec correction 3).
class PublicationSummary {
  final String uuid;
  final String title;
  final int byteSize;
  final DateTime importedAt;
  final String embeddingModelId;
  final int chunkCount;

  const PublicationSummary({
    required this.uuid,
    required this.title,
    required this.byteSize,
    required this.importedAt,
    required this.embeddingModelId,
    required this.chunkCount,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PublicationSummary &&
          other.uuid == uuid &&
          other.title == title &&
          other.byteSize == byteSize &&
          other.importedAt == importedAt &&
          other.embeddingModelId == embeddingModelId &&
          other.chunkCount == chunkCount;

  @override
  int get hashCode =>
      Object.hash(uuid, title, byteSize, importedAt, embeddingModelId, chunkCount);

  @override
  String toString() => 'PublicationSummary($uuid, $title, $chunkCount chunks)';
}

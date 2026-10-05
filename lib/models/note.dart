/// Whether a note's vectors are up to date (spec FR11a, D39).
///
/// [inProcess] means the body changed and the embeddings are being (re)built, or
/// were interrupted mid-build — either way the note must not be treated as
/// searchable until it flips to [complete]. It is **local-only** processing
/// state: it never travels in a sync payload.
enum NoteEmbeddingState {
  complete,
  inProcess;

  static NoteEmbeddingState fromStorage(String value) =>
      value == 'inProcess' ? inProcess : complete;

  String get storage => name;
}

/// A user-authored note (spec FR1, FR5).
///
/// A pure domain value: no `package:flutter`, no `package:objectbox`. The
/// storage entity is `ObNote`/`ObNoteDocument` and the conversion lives in
/// `lib/domain_mapping.dart` (spec NFR1).
///
/// The [body] is stored in its own row and is **not** part of [NoteSummary], so
/// a list path cannot read it even by mistake (spec NFR4).
class Note {
  /// Application-level identity. Stable, generated at creation, never
  /// reassigned. The storage layer's int id must not appear here (spec FR5).
  final String uuid;

  /// Optional. Null means "untitled"; the UI derives a placeholder (spec FR18).
  final String? title;

  /// The note's text. The only input to chunking and embedding (spec FR9).
  final String body;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// Names the model *and configuration* that produced this note's vectors.
  /// Empty when the note has never been indexed.
  final String embeddingModelId;

  /// Denormalised count, so a note list renders without loading chunks
  /// (spec FR12).
  final int chunkCount;

  /// Whether the note's vectors are current (spec FR11a). [inProcess] means a
  /// (re)embed is pending or was interrupted.
  final NoteEmbeddingState embeddingState;

  const Note({
    required this.uuid,
    required this.title,
    required this.body,
    required this.createdAt,
    required this.updatedAt,
    required this.embeddingModelId,
    this.chunkCount = 0,
    this.embeddingState = NoteEmbeddingState.complete,
  });

  /// Distinguishes "title not supplied" from "title explicitly cleared".
  static const Object _unset = Object();

  Note copyWith({
    Object? title = _unset,
    int? chunkCount,
    String? embeddingModelId,
    NoteEmbeddingState? embeddingState,
  }) =>
      Note(
        uuid: uuid,
        title: identical(title, _unset) ? this.title : title as String?,
        body: body,
        createdAt: createdAt,
        updatedAt: updatedAt,
        embeddingModelId: embeddingModelId ?? this.embeddingModelId,
        chunkCount: chunkCount ?? this.chunkCount,
        embeddingState: embeddingState ?? this.embeddingState,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Note &&
          other.uuid == uuid &&
          other.title == title &&
          other.body == body &&
          other.createdAt == createdAt &&
          other.updatedAt == updatedAt &&
          other.embeddingModelId == embeddingModelId &&
          other.chunkCount == chunkCount &&
          other.embeddingState == embeddingState;

  @override
  int get hashCode => Object.hash(
        uuid,
        title,
        body,
        createdAt,
        updatedAt,
        embeddingModelId,
        chunkCount,
        embeddingState,
      );

  @override
  String toString() =>
      'Note($uuid, ${title ?? '(untitled)'}, $chunkCount chunks, '
      '${embeddingState.name})';
}

/// A note's metadata, without its body.
///
/// Returned by every list path. ObjectBox loads whole objects, so a repository
/// that returned the full [Note] from a list would read every body (spec NFR4,
/// FR17).
class NoteSummary {
  final String uuid;
  final String? title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String embeddingModelId;
  final int chunkCount;
  final NoteEmbeddingState embeddingState;

  const NoteSummary({
    required this.uuid,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.embeddingModelId,
    required this.chunkCount,
    this.embeddingState = NoteEmbeddingState.complete,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NoteSummary &&
          other.uuid == uuid &&
          other.title == title &&
          other.createdAt == createdAt &&
          other.updatedAt == updatedAt &&
          other.embeddingModelId == embeddingModelId &&
          other.chunkCount == chunkCount &&
          other.embeddingState == embeddingState;

  @override
  int get hashCode => Object.hash(
      uuid, title, createdAt, updatedAt, embeddingModelId, chunkCount,
      embeddingState);

  @override
  String toString() =>
      'NoteSummary($uuid, ${title ?? '(untitled)'}, $chunkCount chunks, '
      '${embeddingState.name})';
}

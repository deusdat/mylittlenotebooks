import 'package:objectbox/objectbox.dart';

import 'package:mylittlenotebooks/data/objectbox/ob_note_chunk.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_note_document.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_notebook.dart';

/// Storage entity for a user-authored note (spec FR1).
///
/// A note mirrors a publication's grammar: an application-level [uuid], a body
/// in its own row (spec FR2), a many-to-many edge to notebooks (spec FR3), a
/// denormalised [chunkCount], and three independently-versioned sync axes —
/// [versionCounter] (metadata + edges), [chunkSetVersion], and the document's
/// own version.
///
/// The int [id] is an ObjectBox storage detail and must not leak into routes,
/// UI state, or cross-store references (spec FR5).
@Entity()
class ObNote {
  @Id()
  int id = 0;

  @Unique()
  String uuid;

  /// Optional. Null means "untitled"; the UI derives a placeholder (spec FR18).
  String? title;

  @Property(type: PropertyType.dateUtc)
  DateTime createdAt;

  /// Advanced on every write (spec FR16), at the store's millisecond precision.
  @Property(type: PropertyType.dateUtc)
  DateTime updatedAt;

  /// Names the model *and configuration* that produced this note's vectors.
  /// Empty until the note is first indexed (spec FR8).
  String embeddingModelId;

  /// Denormalised, maintained by the transactional chunk write (spec FR12).
  int chunkCount;

  /// `'complete'` or `'inProcess'` (spec FR11a, D39). **Local-only**: it is
  /// processing state, not record data, so it never enters `SyncPayload`.
  /// `inProcess` means the embeddings are being rebuilt or were interrupted and
  /// must be rebuilt at boot.
  String embeddingState;

  /// The metadata + edges axis (spec FR19); the document-body axis lives on
  /// [ObNoteDocument] and the chunk-set axis on [chunkSetVersion].
  @Index()
  int versionCounter;

  /// The chunk-set axis, tracked independently of [versionCounter] so that a
  /// retitle never drags the whole set to a peer (spec FR19).
  int chunkSetVersion;

  /// The many-to-many edge back to notebooks (spec FR3). Reverses
  /// [ObNotebook.notes].
  @Backlink('notes')
  final notebooks = ToMany<ObNotebook>();

  /// The note's chunks, reversed from [ObNoteChunk.note] (spec FR21).
  @Backlink('note')
  final chunks = ToMany<ObNoteChunk>();

  final document = ToOne<ObNoteDocument>();

  ObNote({
    required this.uuid,
    this.title,
    required this.createdAt,
    required this.updatedAt,
    this.embeddingModelId = '',
    this.chunkCount = 0,
    this.embeddingState = 'complete',
    this.versionCounter = 0,
    this.chunkSetVersion = 0,
  });
}

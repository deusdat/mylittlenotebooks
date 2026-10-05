import 'package:objectbox/objectbox.dart';

import 'package:mylittlenotebooks/data/objectbox/ob_note.dart';

/// Storage entity for one indexed slice of a note's body (spec FR4).
///
/// A separate entity from `ObChunk` on purpose (spec D2): sharing it would force
/// a schema change to the publication search path and a nullable parent column.
/// The cost is a second HNSW index in the same store (spec NFR8).
@Entity()
class ObNoteChunk {
  @Id()
  int id = 0;

  /// Derived identity: `noteChunkUuidFor(noteUuid, chunkIndex)` (spec FR25).
  /// Derivation makes re-applying a whole set idempotent.
  @Unique()
  String uuid;

  /// 0-based and contiguous within a note — a contract the chunker honours
  /// (spec FR6).
  int chunkIndex;

  String content;

  int tokenCount;

  /// Denormalised from [ObNote] and indexed.
  ///
  /// Load-bearing: `nearestNeighborsF32`'s `maxResultCount` bounds the ANN
  /// sub-query, so the `noteId` filter must be a flat, index-backed scalar
  /// condition (spec FR35, `FetchBudget`).
  @Index()
  int noteId;

  @HnswIndex(
    dimensions: 256,
    distanceType: VectorDistanceType.cosine,
    neighborsPerNode: 16,
    indexingSearchCount: 100,
  )
  @Property(type: PropertyType.floatVector)
  List<double> embedding;

  /// The rename is mandatory: a `ToOne` named `note` would generate `noteId`,
  /// colliding with the denormalised column (spec FR4, the `publicationRef`
  /// failure repeating).
  @TargetIdProperty('noteRef')
  final note = ToOne<ObNote>();

  ObNoteChunk({
    required this.uuid,
    required this.chunkIndex,
    required this.content,
    required this.tokenCount,
    required this.noteId,
    required this.embedding,
  });
}

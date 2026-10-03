import 'package:objectbox/objectbox.dart';

import 'package:mylittlenotebooks/data/objectbox/ob_publication.dart';

/// Storage entity for one indexed slice of a publication (spec FR2).
@Entity()
class ObChunk {
  @Id()
  int id = 0;

  /// Globally-unique identity, shared with peer devices.
  ///
  /// **Derived, never randomly generated**: it is a pure function of
  /// `(publication.uuid, chunkIndex)` via `chunkUuidFor`. That makes identity
  /// need no coordination — two devices compute the same value independently —
  /// and makes re-applying a whole chunk set idempotent, which matters because
  /// ingest replaces chunk sets wholesale rather than merging them.
  ///
  /// `@Unique` rather than `@Index` — see the note on `ObNotebook.uuid`.
  @Unique()
  String uuid;

  /// 0-based and contiguous within a publication — a contract the chunker must
  /// honour (spec FR2, Open Questions).
  int chunkIndex;

  String content;

  int tokenCount;

  /// Denormalised from [ObPublication] and indexed.
  ///
  /// This is **load-bearing**, not a convenience (spec FR7). Scoped vector
  /// search needs to filter chunks by publication, and ObjectBox relation
  /// traversal is a `QueryBuilder` method (`link()`, `backlinkMany()`) that
  /// re-targets the builder at another entity — it produces no condition, so it
  /// cannot be `.and()`-ed with `nearestNeighborsF32`. This flat column turns
  /// the filter into an index-backed scalar condition that composes with the
  /// vector query in a single expression.
  @Index()
  int publicationId;

  /// The approximate-nearest-neighbour index.
  ///
  /// `dimensions` is a fixed property of the index, and it **triggers a full
  /// re-index when changed**. Note ObjectBox silently ignores any vector with
  /// fewer dimensions than declared here — it stores without throwing, and the
  /// chunk becomes unfindable. That is why length is validated at the write
  /// boundary instead (spec FR8, plan R7).
  ///
  /// `distanceType: cosine` is not load-bearing: vectors are L2-normalised
  /// after Matryoshka truncation, so cosine and euclidean rank identically
  /// (spec D10).
  @HnswIndex(
    dimensions: 256,
    distanceType: VectorDistanceType.cosine,
    neighborsPerNode: 16,
    indexingSearchCount: 100,
  )
  @Property(type: PropertyType.floatVector)
  List<double> embedding;

  /// The real relation, used for navigation from `ObPublication.chunks`.
  ///
  /// Not used for querying — [publicationId] is (spec FR7). Both are written in
  /// the same transaction so they cannot drift, and a test asserts it.
  ///
  /// The `@TargetIdProperty` rename is **mandatory, not stylistic**. ObjectBox
  /// auto-generates a target-ID property named `<toOneName>Id` for every
  /// `ToOne`; this one is called `publication`, so it would generate
  /// `publicationId` — colliding with the denormalised column above and failing
  /// codegen with a name conflict. Renaming either side of that pair silently
  /// breaks scoped search, because the queries reference `Chunk_.publicationId`
  /// (spec defect 1, plan D1, plan R5).
  @TargetIdProperty('publicationRef')
  final publication = ToOne<ObPublication>();

  ObChunk({
    required this.uuid,
    required this.chunkIndex,
    required this.content,
    required this.tokenCount,
    required this.publicationId,
    required this.embedding,
  });
}

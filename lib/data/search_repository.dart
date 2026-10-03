import 'package:mylittlenotebooks/data/embedding_validation.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_chunk.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_notebook.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_publication.dart';
import 'package:mylittlenotebooks/domain_mapping.dart';
import 'package:mylittlenotebooks/models/search_result.dart';
import 'package:mylittlenotebooks/objectbox.g.dart';

/// Vector retrieval over the chunk set (spec FR13–FR16).
///
/// Takes **ObjectBox ids**, not uuids. The vector path should not pay for
/// string lookups, and keeping the uuid→id resolution above this layer stops
/// the two id kinds from leaking inward (spec FR5, plan I3).
abstract interface class SearchRepository {
  /// The nearest chunks to [queryVector], ascending by distance.
  ///
  /// [publicationIds] distinguishes two cases that are **not** the same:
  ///
  ///  - `null` — no scope was requested; search the whole corpus (spec FR13).
  ///  - `[]`   — a scope *was* requested and it matches nothing; return
  ///    nothing (spec FR16). This is what a notebook with no publications, or
  ///    a deleted one, resolves to.
  ///
  /// Collapsing these into one empty-list case makes a search scoped to a
  /// nonexistent notebook return the entire corpus, which is the single worst
  /// failure this interface could have.
  List<SearchResult> search({
    required List<double> queryVector,
    required List<int>? publicationIds,
    required int limit,
    /// Test seam: bypass the computed over-fetch and use this candidate count.
    /// Exists so a test can prove the naive `fetchCount == limit` behaviour
    /// actually fails, rather than asserting the mechanism in prose (plan R4).
    int? fetchCountOverride,
  });

  /// Resolves uuids to the int ids this interface takes.
  List<int> resolvePublicationIds(List<String> publicationUuids);

  /// Resolves a notebook uuid to every publication id attached to it — the
  /// scope for a notebook-scoped search.
  List<int> resolveNotebookScope(String notebookUuid);
}

/// How many candidates the ANN sub-query must consider to reliably satisfy a
/// filtered search (spec FR15, plan D2).
///
/// **This is the single most important constant in the retrieval path.**
/// ObjectBox applies `nearestNeighborsF32`'s `maxResultCount` to the ANN
/// sub-query *only*; the scope filter is applied to those candidates afterwards.
/// So asking for exactly `limit` candidates and then filtering returns
/// **fewer than `limit` results — including zero** whenever the unfiltered
/// nearest neighbours fall outside the scope.
///
/// Measured during planning on a 5%-scope corpus:
///
/// | Total chunks | `1 / fraction` | Multiplier that actually worked |
/// |---|---|---|
/// | 2,000  | 20 | **30** (×1.5) |
/// | 20,000 | 20 | **15** (×0.75) |
///
/// `1 / fraction` is therefore a **lower bound, not a guarantee**, and the
/// shortfall is not a constant factor — it moved with corpus size. The `×2`
/// safety factor clears both measurements; the clamp bounds the opposite
/// failure, where an unbounded multiplier on a very narrow scope over a large
/// corpus would request more candidates than the corpus holds.
abstract final class FetchBudget {
  /// Safety factor over `1 / fraction`.
  static const int safetyFactor = 2;

  /// Upper bound on candidates, regardless of how narrow the scope is.
  static const int maxFetchCount = 1000;

  static int forLimit({
    required int limit,
    required double scopeFraction,
  }) {
    if (limit <= 0) return 0;
    // An empty or unknown scope searches everything, so no over-fetch is needed
    // beyond a small margin.
    if (scopeFraction >= 1.0) return limit * safetyFactor;

    final fraction = scopeFraction <= 0.0 ? 1.0 / safetyFactor : scopeFraction;
    final needed = (limit / fraction * safetyFactor).ceil();
    return needed.clamp(limit, maxFetchCount);
  }
}

class ObjectBoxSearchRepository implements SearchRepository {
  ObjectBoxSearchRepository(this._store)
      : _chunks = _store.box<ObChunk>(),
        _publications = _store.box<ObPublication>();

  final Store _store;
  final Box<ObChunk> _chunks;
  final Box<ObPublication> _publications;

  @override
  List<SearchResult> search({
    required List<double> queryVector,
    required List<int>? publicationIds,
    required int limit,
    int? fetchCountOverride,
  }) {
    validateEmbedding(queryVector);
    if (limit <= 0) return const [];

    // `null` means no scope; `[]` means an empty scope. Both are honoured
    // rather than collapsed (spec FR13 vs FR16).
    final scoped = publicationIds != null;
    final ids = publicationIds ?? const <int>[];

    // An explicitly empty scope matches nothing, and must not fall back to the
    // whole corpus (spec FR16).
    if (scoped && ids.isEmpty) return const [];

    // Cheap `count()` per scope, never a chunk load (spec NFR6).
    final total = _chunks.count();
    final scopeCount = scoped ? _countChunks(ids) : total;
    final fraction = total > 0 ? scopeCount / total : 1.0;
    final fetchCount = fetchCountOverride ??
        FetchBudget.forLimit(limit: limit, scopeFraction: fraction);

    final condition =
        ObChunk_.embedding.nearestNeighborsF32(queryVector, fetchCount);
    final query = _chunks.query(
      scoped ? condition.and(ObChunk_.publicationId.oneOf(ids)) : condition,
    ).build();

    try {
      final hits = query.findWithScores();
      final byUuid = _publicationUuids(ids);

      return hits
          // `maxResultCount` bounds candidates, so the ANN can legitimately
          // return more than `limit` once the filter is applied. Truncate here
          // — ObjectBox does not, because `limit` is a query setting it applies
          // before scoring.
          .take(limit)
          .map((hit) => SearchResult(
                chunk: hit.object.toDomain(
                  publicationUuid: byUuid[hit.object.publicationId] ?? '',
                ),
                distance: hit.score,
              ))
          .toList();
    } finally {
      query.close();
    }
  }

  @override
  List<int> resolvePublicationIds(List<String> publicationUuids) {
    if (publicationUuids.isEmpty) return const [];
    final ids = <int>[];
    for (final uuid in publicationUuids) {
      final query = _publications.query(ObPublication_.uuid.equals(uuid)).build();
      try {
        final found = query.findFirst();
        if (found != null) ids.add(found.id);
      } finally {
        query.close();
      }
    }
    return ids;
  }

  @override
  List<int> resolveNotebookScope(String notebookUuid) {
    // Reach the notebook, then read its `ToMany` — one indexed lookup plus one
    // lazy relation load, rather than a query per publication.
    final notebooks = _store.box<ObNotebook>();
    final notebookQuery =
        notebooks.query(ObNotebook_.uuid.equals(notebookUuid)).build();
    try {
      final notebook = notebookQuery.findFirst();
      if (notebook == null) return const [];
      return notebook.publications.map((p) => p.id).toList();
    } finally {
      notebookQuery.close();
    }
  }

  int _countChunks(List<int> publicationIds) {
    final query = _chunks
        .query(ObChunk_.publicationId.oneOf(publicationIds))
        .build();
    try {
      return query.count();
    } finally {
      query.close();
    }
  }

  /// Maps int ids back to uuids so the domain layer never sees an int.
  Map<int, String> _publicationUuids(List<int> ids) {
    if (ids.isEmpty) {
      final all = _publications.getAll();
      return {for (final p in all) p.id: p.uuid};
    }
    final map = <int, String>{};
    for (final id in ids) {
      final entity = _publications.get(id);
      if (entity != null) map[id] = entity.uuid;
    }
    return map;
  }
}

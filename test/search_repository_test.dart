import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/data/objectbox/objectbox_store.dart';
import 'package:mylittlenotebooks/data/objectbox_library_repository.dart';
import 'package:mylittlenotebooks/data/objectbox_notebook_repository.dart';
import 'package:mylittlenotebooks/data/search_repository.dart';
import 'package:mylittlenotebooks/models/chunk.dart';
import 'package:objectbox/objectbox.dart';

const model = 'test-model:int8:256';

List<double> unitVector(int seed, {int dims = 256}) {
  final random = Random(seed);
  final values = List<double>.filled(dims, 0);
  for (var i = 0; i < dims; i++) {
    values[i] = random.nextDouble() - 0.5;
  }
  final norm = sqrt(values.fold<double>(0, (a, b) => a + b * b));
  return values.map((v) => v / norm).toList();
}

/// A corpus of [publicationCount] publications, [chunksPerPublication] each.
///
/// Seeds are laid out so publication `p` owns the vector cluster
/// `p * stride + i`. That lets a test aim a query vector at one publication's
/// cluster while scoping to a *different* one — which is what makes the search
/// adversarial rather than friendly.
({List<int> ids, List<String> uuids}) seedCorpus(
  Store store,
  ObjectBoxLibraryRepository library, {
  required int publicationCount,
  required int chunksPerPublication,
}) {
  final ids = <int>[];
  final uuids = <String>[];
  for (var p = 0; p < publicationCount; p++) {
    final publication = library.create(
      title: 'P$p',
      sourceMarkdown: 'document $p',
      embeddingModelId: model,
    );
    uuids.add(publication.uuid);
    library.replaceChunks(
      publication.uuid,
      [
        for (var i = 0; i < chunksPerPublication; i++)
          ChunkDraft(
            chunkIndex: i,
            content: 'p$p chunk $i',
            tokenCount: 2,
            embedding: unitVector(p * 100000 + i),
          ),
      ],
    );
  }
  final search = ObjectBoxSearchRepository(store);
  for (final uuid in uuids) {
    ids.add(search.resolvePublicationIds([uuid]).single);
  }
  return (ids: ids, uuids: uuids);
}

void main() {
  late Store store;
  late ObjectBoxLibraryRepository library;
  late ObjectBoxNotebookRepository notebooks;
  late ObjectBoxSearchRepository search;

  setUp(() {
    store = openTestStore('search');
    library = ObjectBoxLibraryRepository(store);
    notebooks = ObjectBoxNotebookRepository(store);
    search = ObjectBoxSearchRepository(store);
  });

  tearDown(() => store.close());

  group('AC14 — scoped and unscoped share one path', () {
    test('a scope returns only its own chunks', () {
      final corpus = seedCorpus(
        store,
        library,
        publicationCount: 5,
        chunksPerPublication: 20,
      );

      final scoped = search.search(
        queryVector: unitVector(0),
        publicationIds: [corpus.ids[1]],
        limit: 10,
      );

      expect(scoped, hasLength(10));
      final allowed = corpus.uuids[1];
      expect(
        scoped.every((r) => r.chunk.publicationUuid == allowed),
        isTrue,
        reason: 'every hit must belong to the requested publication',
      );
    });

    test('a multi-publication scope returns chunks from both', () {
      final corpus = seedCorpus(
        store,
        library,
        publicationCount: 4,
        chunksPerPublication: 30,
      );

      final hits = search.search(
        queryVector: unitVector(0),
        publicationIds: [corpus.ids[0], corpus.ids[3]],
        limit: 20,
      );

      expect(hits, hasLength(20));
      final seen = hits.map((r) => r.chunk.publicationUuid).toSet();
      expect(seen, {corpus.uuids[0], corpus.uuids[3]});
    });

    test('an empty scope searches everything, through the same function', () {
      seedCorpus(
        store,
        library,
        publicationCount: 4,
        chunksPerPublication: 25,
      );

      final unscoped = search.search(
        queryVector: unitVector(0),
        publicationIds: null,
        limit: 10,
      );

      expect(unscoped, hasLength(10));
      expect(
        unscoped.map((r) => r.chunk.publicationUuid).toSet(),
        hasLength(greaterThan(1)),
        reason: 'an unscoped search should span publications',
      );
    });

    test('a notebook scope resolves through the association', () {
      final corpus = seedCorpus(
        store,
        library,
        publicationCount: 4,
        chunksPerPublication: 20,
      );
      final notebook = notebooks.create();
      library
        ..attach(corpus.uuids[0], notebook.id)
        ..attach(corpus.uuids[2], notebook.id);

      final scope = search.resolveNotebookScope(notebook.id);
      expect(scope..sort(), [corpus.ids[0], corpus.ids[2]]..sort());

      final hits = search.search(
        queryVector: unitVector(0),
        publicationIds: scope,
        limit: 10,
      );
      expect(hits, hasLength(10));
      final allowed = {corpus.uuids[0], corpus.uuids[2]};
      expect(
        hits.map((r) => r.chunk.publicationUuid).where((u) => !allowed.contains(u)),
        isEmpty,
        reason: 'a notebook-scoped search must not leak other publications',
      );
    });
  });

  group('AC15 — an empty scope returns empty, never everything', () {
    test('ids matching nothing yield no results', () {
      seedCorpus(
        store,
        library,
        publicationCount: 3,
        chunksPerPublication: 20,
      );

      final hits = search.search(
        queryVector: unitVector(0),
        publicationIds: const [999999],
        limit: 10,
      );

      expect(hits, isEmpty,
          reason: 'there must be no fallback to an unscoped search (FR16)');
    });

    test('an explicitly empty scope is empty, not "everything"', () {
      seedCorpus(
        store,
        library,
        publicationCount: 3,
        chunksPerPublication: 20,
      );

      // `[]` and `null` are different requests. Conflating them makes a search
      // scoped to a notebook with no publications return the entire corpus —
      // the worst possible failure of this interface (spec FR13 vs FR16).
      expect(
        search.search(
          queryVector: unitVector(0),
          publicationIds: const [],
          limit: 10,
        ),
        isEmpty,
      );
      expect(
        search.search(
          queryVector: unitVector(0),
          publicationIds: null,
          limit: 10,
        ),
        hasLength(10),
      );
    });

    test('a notebook with no publications scopes to nothing', () {
      seedCorpus(
        store,
        library,
        publicationCount: 3,
        chunksPerPublication: 20,
      );

      final emptyNotebook = notebooks.create();
      expect(search.resolveNotebookScope(emptyNotebook.id), isEmpty);
      expect(
        search.search(
          queryVector: unitVector(0),
          publicationIds: search.resolveNotebookScope(emptyNotebook.id),
          limit: 10,
        ),
        isEmpty,
      );
    });

    test('an unknown notebook resolves to an empty scope, which is still empty',
        () {
      seedCorpus(
        store,
        library,
        publicationCount: 3,
        chunksPerPublication: 20,
      );

      expect(search.resolveNotebookScope('no-such-notebook'), isEmpty);
      expect(
        search.search(
          queryVector: unitVector(0),
          publicationIds: search.resolveNotebookScope('no-such-notebook'),
          limit: 10,
        ),
        isEmpty,
        reason: 'a deleted notebook must not leak the whole corpus',
      );
    });
  });

  group('AC16 — a narrow scope still returns the full limit', () {
    // This is the spec's most important test. ObjectBox applies
    // `maxResultCount` to the ANN sub-query only and filters afterwards, so
    // asking for exactly `limit` candidates silently returns fewer — including
    // zero — when the unfiltered nearest neighbours fall outside the scope.
    //
    // The corpus and query vector below were measured during planning: the
    // naive implementation returned **0 of 10** results on this shape.

    /// Aims the query at publication 19's cluster while scoping to
    /// publication 0, so the unfiltered top-N are all out of scope.
    ({List<int> ids, List<String> uuids}) adversarialCorpus() => seedCorpus(
          store,
          library,
          publicationCount: 20,
          chunksPerPublication: 100,
        );

    test('returns exactly `limit` results on an adversarial corpus', () {
      final corpus = adversarialCorpus();
      final hits = search.search(
        queryVector: unitVector(19 * 100000),
        publicationIds: [corpus.ids[0]],
        limit: 10,
      );

      expect(
        hits,
        hasLength(10),
        reason: 'a scoped search must satisfy its limit (spec FR15)',
      );
      expect(
        hits.every((r) => r.chunk.publicationUuid == corpus.uuids[0]),
        isTrue,
      );
    });

    test('the corpus really is adversarial', () {
      // Guards the test itself. If the unfiltered top-`limit` were already in
      // scope, the naive implementation would pass and this file would guard
      // nothing — which is precisely how a search regression ships unnoticed
      // (plan R4).
      final corpus = adversarialCorpus();
      final unscoped = search.search(
        queryVector: unitVector(19 * 100000),
        publicationIds: null,
        limit: 10,
      );

      expect(unscoped, hasLength(10));
      expect(
        unscoped.every((r) => r.chunk.publicationUuid != corpus.uuids[0]),
        isTrue,
        reason: 'the unfiltered top-10 must be entirely out of scope, or this '
            'test is vacuous',
      );
    });

    test('the naive fetch count demonstrably fails on this corpus', () {
      // Documents *why* over-fetching exists by running the broken behaviour,
      // not by asserting the formula in prose. If this ever starts passing, the
      // adversarial corpus has stopped being adversarial (plan R4).
      final corpus = adversarialCorpus();
      final queryVector = unitVector(19 * 100000);

      final naive = search.search(
        queryVector: queryVector,
        publicationIds: [corpus.ids[0]],
        limit: 10,
        // `fetchCount == limit` — the obvious implementation, and the bug.
        fetchCountOverride: 10,
      );
      expect(
        naive.length,
        lessThan(10),
        reason: 'the naive fetch count must visibly under-deliver, otherwise '
            'this test proves nothing',
      );

      final correct = search.search(
        queryVector: queryVector,
        publicationIds: [corpus.ids[0]],
        limit: 10,
      );
      expect(correct, hasLength(10));
    });

    test('holds at a larger corpus size', () {
      // The measured shortfall in `1 / fraction` moved with corpus size
      // (×1.5 at 2,000 chunks, ×0.75 at 20,000), so the budget is pinned at
      // both scales rather than one.
      final corpus = seedCorpus(
        store,
        library,
        publicationCount: 20,
        chunksPerPublication: 500,
      );
      final hits = search.search(
        queryVector: unitVector(19 * 100000),
        publicationIds: [corpus.ids[0]],
        limit: 10,
      );
      expect(hits, hasLength(10));
    });

    test('a very narrow scope is still bounded, not unbounded', () {
      final corpus = seedCorpus(
        store,
        library,
        publicationCount: 50,
        chunksPerPublication: 20,
      );
      final hits = search.search(
        queryVector: unitVector(49 * 100000),
        publicationIds: [corpus.ids[0]],
        limit: 10,
      );
      expect(hits, hasLength(10));
      // The clamp keeps the request finite even at a 2% scope.
      expect(
        FetchBudget.forLimit(limit: 10, scopeFraction: 0.02),
        lessThanOrEqualTo(FetchBudget.maxFetchCount),
      );
    });
  });

  group('AC17 — ordering and score semantics', () {
    test('results are ordered by increasing distance', () {
      seedCorpus(
        store,
        library,
        publicationCount: 5,
        chunksPerPublication: 40,
      );

      final hits = search.search(
        queryVector: unitVector(3),
        publicationIds: null,
        limit: 20,
      );

      expect(hits, hasLength(20));
      for (var i = 1; i < hits.length; i++) {
        expect(
          hits[i].distance,
          greaterThanOrEqualTo(hits[i - 1].distance),
          reason: 'distance is ascending, so smaller is nearer (spec FR14)',
        );
      }
    });

    test('an identical vector scores lower than an orthogonal one', () {
      final target = library.create(
        title: 'Target',
        sourceMarkdown: 'target',
        embeddingModelId: model,
      );
      final probe = unitVector(1234);
      library.replaceChunks(target.uuid, [
        ChunkDraft(
          chunkIndex: 0,
          content: 'exact',
          tokenCount: 1,
          embedding: probe,
        ),
        ChunkDraft(
          chunkIndex: 1,
          content: 'orthogonal',
          tokenCount: 1,
          // Unit basis vector in a different direction: as far from `probe`
          // as a normalised vector can be.
          embedding: _orthogonalTo(probe),
        ),
      ]);

      final hits = search.search(
        queryVector: probe,
        publicationIds: search.resolvePublicationIds([target.uuid]),
        limit: 2,
      );

      expect(hits, hasLength(2));
      expect(hits.first.chunk.content, 'exact');
      expect(
        hits.first.distance,
        lessThan(hits.last.distance),
        reason: 'smaller distance means nearer — the inverse of a score',
      );
    });

    test('the limit is respected even when the ANN returns more', () {
      seedCorpus(
        store,
        library,
        publicationCount: 3,
        chunksPerPublication: 50,
      );
      final hits = search.search(
        queryVector: unitVector(0),
        publicationIds: null,
        limit: 5,
      );
      expect(hits, hasLength(5));
    });

    test('a limit of zero returns nothing without touching the store', () {
      seedCorpus(
        store,
        library,
        publicationCount: 2,
        chunksPerPublication: 10,
      );
      expect(
        search.search(
          queryVector: unitVector(0),
          publicationIds: null,
          limit: 0,
        ),
        isEmpty,
      );
    });

    test('an empty corpus returns nothing rather than throwing', () {
      expect(
        search.search(
          queryVector: unitVector(0),
          publicationIds: null,
          limit: 10,
        ),
        isEmpty,
      );
    });
  });

  group('FetchBudget', () {
    test('an unscoped search only needs a small margin', () {
      expect(FetchBudget.forLimit(limit: 10, scopeFraction: 1.0), 20);
    });

    test('a 5% scope over-fetches by at least the safety factor', () {
      // 10 / 0.05 * 2 = 400
      expect(FetchBudget.forLimit(limit: 10, scopeFraction: 0.05), 400);
    });

    test('a tiny scope is clamped', () {
      expect(
        FetchBudget.forLimit(limit: 10, scopeFraction: 0.00001),
        FetchBudget.maxFetchCount,
      );
    });

    test('a zero or negative limit yields zero', () {
      expect(FetchBudget.forLimit(limit: 0, scopeFraction: 0.05), 0);
      expect(FetchBudget.forLimit(limit: -5, scopeFraction: 1.0), 0);
    });

    test('a zero fraction does not divide by zero', () {
      expect(
        FetchBudget.forLimit(limit: 10, scopeFraction: 0),
        greaterThanOrEqualTo(10),
      );
    });

    test('the result is never below the limit', () {
      for (final fraction in [1.0, 0.5, 0.1, 0.01, 0.0001]) {
        expect(
          FetchBudget.forLimit(limit: 7, scopeFraction: fraction),
          greaterThanOrEqualTo(7),
        );
      }
    });
  });
}

/// A unit vector as close to orthogonal to [v] as a 256-dim space allows:
/// subtract the projection and renormalise.
List<double> _orthogonalTo(List<double> v) {
  final dot = v[0];
  final out = List<double>.filled(v.length, 0);
  for (var i = 0; i < v.length; i++) {
    out[i] = v[i] - dot * v[0];
  }
  final norm = sqrt(out.fold<double>(0, (a, b) => a + b * b));
  return out.map((e) => e / norm).toList();
}

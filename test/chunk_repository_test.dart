import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/data/embedding_validation.dart';
import 'package:mylittlenotebooks/data/invalid_embedding_exception.dart';
import 'package:mylittlenotebooks/data/objectbox/objectbox_store.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_chunk.dart';
import 'package:mylittlenotebooks/data/objectbox_library_repository.dart';
import 'package:mylittlenotebooks/data/objectbox_publication_repository.dart';
import 'package:mylittlenotebooks/data/search_repository.dart';
import 'package:mylittlenotebooks/domain_mapping.dart';
import 'package:mylittlenotebooks/objectbox.g.dart';
import 'package:mylittlenotebooks/models/chunk.dart';

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

ChunkDraft draft(
  int index, {
  int seed = 0,
  String? content,
  List<double>? embedding,
}) =>
    ChunkDraft(
      chunkIndex: index,
      content: content ?? 'chunk $index',
      tokenCount: 3,
      embedding: embedding ?? unitVector(seed),
    );

void main() {
  late Store store;
  late ObjectBoxLibraryRepository library;
  late ObjectBoxPublicationRepository publications;
  late ObjectBoxSearchRepository search;
  late String publicationUuid;
  late int publicationId;

  setUp(() {
    store = openTestStore('chunks');
    library = ObjectBoxLibraryRepository(store);
    publications = ObjectBoxPublicationRepository(store);
    search = ObjectBoxSearchRepository(store);
    final created = library.create(
      title: 'Doc',
      sourceMarkdown: '# doc',
      embeddingModelId: model,
    );
    publicationUuid = created.uuid;
    publicationId = search.resolvePublicationIds([publicationUuid]).single;
  });

  tearDown(() => store.close());

  group('AC9 — the two representations of the parent never diverge', () {
    test('publicationId equals publication.targetId for every chunk', () {
      final other = library.create(
        title: 'Other',
        sourceMarkdown: 'other',
        embeddingModelId: model,
      );
      library
        ..replaceChunks(publicationUuid, [draft(0), draft(1, seed: 1)])
        ..replaceChunks(
          other.uuid,
          [draft(0, seed: 9), draft(1, seed: 10), draft(2, seed: 11)],
        );

      final chunks = store.box<ObChunk>().getAll();
      expect(chunks, hasLength(5));
      for (final chunk in chunks) {
        expect(
          chunk.publicationId,
          chunk.publication.targetId,
          reason: 'chunk #${chunk.chunkIndex} has a divergent parent '
              '(spec FR7, plan R6)',
        );
      }
    });

    test('a re-index keeps the invariant', () {
      library.replaceChunks(publicationUuid, [draft(0)]);
      library.replaceChunks(publicationUuid, [draft(0, seed: 5), draft(1, seed: 6)]);

      final chunks = store.box<ObChunk>().getAll();
      expect(chunks, hasLength(2));
      for (final chunk in chunks) {
        expect(chunk.publicationId, chunk.publication.targetId);
        expect(chunk.publicationId, publicationId);
      }
    });
  });

  group('AC8 — malformed vectors are refused before any write', () {
    test('wrong lengths are rejected, including the silently-ignored 128', () {
      // 128 is the case that matters most: ObjectBox indexes only up to
      // `dimensions`, so this vector would store without throwing and become
      // unfindable by search. It was measured to do exactly that (plan R7).
      for (final dims in [1, 128, 255, 257, 512, 0]) {
        expect(
          () => library.replaceChunks(publicationUuid, [
            draft(0, embedding: List<double>.filled(dims, 0.1)),
          ]),
          throwsA(isA<InvalidEmbeddingException>()),
          reason: 'a $dims-dimension vector must be rejected',
        );
      }
      expect(store.box<ObChunk>().count(), 0,
          reason: 'no chunk may be written when one draft is malformed');
    });

    test('the exception reports both lengths', () {
      try {
        library.replaceChunks(publicationUuid, [
          draft(0, embedding: List<double>.filled(128, 0.1)),
        ]);
        fail('expected InvalidEmbeddingException');
      } on InvalidEmbeddingException catch (error) {
        expect(error.actualLength, 128);
        expect(error.expectedLength, VectorGeometry.dimensions);
      }
    });

    test('non-finite values are rejected', () {
      final poisoned = unitVector(0)..[7] = double.nan;
      expect(
        () => library.replaceChunks(publicationUuid, [draft(0, embedding: poisoned)]),
        throwsA(isA<InvalidEmbeddingException>()),
      );

      final infinite = unitVector(0)..[3] = double.infinity;
      expect(
        () => library.replaceChunks(publicationUuid, [draft(0, embedding: infinite)]),
        throwsA(isA<InvalidEmbeddingException>()),
      );

      expect(store.box<ObChunk>().count(), 0);
    });

    test('one bad draft rejects the whole batch', () {
      expect(
        () => library.replaceChunks(publicationUuid, [
          draft(0),
          draft(1, seed: 1),
          draft(2, embedding: List<double>.filled(10, 0.5)),
        ]),
        throwsA(isA<InvalidEmbeddingException>()),
      );
      expect(store.box<ObChunk>().count(), 0);
    });

    test('a bad query vector is refused too', () {
      library.replaceChunks(publicationUuid, [draft(0)]);
      expect(
        () => search.search(
          queryVector: List<double>.filled(64, 0.1),
          publicationIds: [publicationId],
          limit: 5,
        ),
        throwsA(isA<InvalidEmbeddingException>()),
      );
    });
  });

  group('AC10 — chunkCount tracks reality', () {
    test('after create, re-index, and delete', () {
      library.replaceChunks(publicationUuid, [draft(0)]);
      expect(publications.byUuid(publicationUuid)!.chunkCount, 1);

      library.replaceChunks(publicationUuid, [
        draft(0, seed: 1),
        draft(1, seed: 2),
        draft(2, seed: 3),
      ]);
      expect(publications.byUuid(publicationUuid)!.chunkCount, 3);
      expect(store.box<ObChunk>().count(), 3);

      library.deletePublication(publicationUuid);
      expect(publications.byUuid(publicationUuid), isNull);
    });

    test('a fresh publication reports zero', () {
      expect(publications.byUuid(publicationUuid)!.chunkCount, 0);
    });

    test('after a FAILED re-index the previous count and chunks survive', () {
      library.replaceChunks(publicationUuid, [
        draft(0, seed: 1),
        draft(1, seed: 2),
      ]);

      // A batch whose third draft is malformed: validation rejects it before
      // the transaction opens, so nothing is disturbed.
      expect(
        () => library.replaceChunks(publicationUuid, [
          draft(0, seed: 7),
          draft(1, seed: 8),
          draft(2, embedding: List<double>.filled(3, 0.2)),
        ]),
        throwsA(isA<InvalidEmbeddingException>()),
      );

      expect(publications.byUuid(publicationUuid)!.chunkCount, 2);
      expect(store.box<ObChunk>().count(), 2);
      expect(
        search.search(
          queryVector: unitVector(1),
          publicationIds: [publicationId],
          limit: 10,
        ),
        hasLength(2),
        reason: 'a rejected re-index must leave the publication searchable',
      );
    });
  });

  group('AC11 — a chunk-set replacement is atomic', () {
    test('a throw inside the transaction leaves the prior set intact', () {
      library.replaceChunks(publicationUuid, [
        draft(0, content: 'original zero'),
        draft(1, content: 'original one'),
      ]);
      final before = store
          .box<ObChunk>()
          .getAll()
          .map((c) => c.content)
          .toSet();

      // Roll the transaction from inside, after the old chunks have already
      // been removed and the new ones inserted. A transaction that is never
      // actually rolled back has not been tested (tasks T17 step 6).
      //
      // ObjectBox wraps a failing transaction callback in an `UnsupportedError`
      // rather than propagating the original exception, so the assertion is on
      // the rollback, not on the exception type.
      expect(
        () => store.runInTransaction(TxMode.write, () {
          final stale = store
              .box<ObChunk>()
              .query(ObChunk_.publicationId.equals(publicationId))
              .build();
          stale.remove();
          stale.close();
          // Uses the production mapping rather than a local copy, so this test
          // exercises the code that ingest will use.
          store.box<ObChunk>().putMany([
            draft(0, seed: 42, content: 'replacement').toEntity(
              publicationId: publicationId,
              publicationUuid: publicationUuid,
            ),
          ]);
          throw StateError('simulated failure mid-write');
        }),
        throwsA(isA<Error>()),
      );

      final after = store
          .box<ObChunk>()
          .getAll()
          .map((c) => c.content)
          .toSet();
      expect(after, before,
          reason: 'a rolled-back transaction must restore the prior chunks');
      expect(publications.byUuid(publicationUuid)!.chunkCount, 2);
      expect(
        search.search(
          queryVector: unitVector(1),
          publicationIds: [publicationId],
          limit: 10,
        ),
        hasLength(2),
        reason: 'the publication must still be searchable after a rollback',
      );
    });

    test('the count and the chunk set agree after every operation', () {
      // Whatever route a write takes, the denormalised count must never
      // disagree with the rows it summarises — otherwise a publication renders
      // as healthy while content is missing (spec FR9, plan R8).
      void expectConsistent() {
        final query = store
            .box<ObChunk>()
            .query(ObChunk_.publicationId.equals(publicationId))
            .build();
        final actual = query.count();
        query.close();
        expect(publications.byUuid(publicationUuid)!.chunkCount, actual);
      }

      expectConsistent();

      library.replaceChunks(publicationUuid, [draft(0)]);
      expectConsistent();

      library.replaceChunks(publicationUuid, [
        draft(0, seed: 1),
        draft(1, seed: 2),
        draft(2, seed: 3),
        draft(3, seed: 4),
      ]);
      expectConsistent();

      expect(
        () => library.replaceChunks(publicationUuid, [
          draft(0, seed: 5),
          draft(1, embedding: List<double>.filled(9, 0.1)),
        ]),
        throwsA(isA<InvalidEmbeddingException>()),
      );
      expectConsistent();

      library.replaceChunks(publicationUuid, const []);
      expectConsistent();
    });
  });

  group('re-index is idempotent', () {
    test('running it twice leaves the same set, not a doubled one', () {
      List<ChunkDraft> batch(int salt) => [
            draft(0, seed: 100 + salt),
            draft(1, seed: 200 + salt),
            draft(2, seed: 300 + salt),
          ];

      library.replaceChunks(publicationUuid, batch(0));
      final first = store
          .box<ObChunk>()
          .getAll()
          .map((c) => '${c.chunkIndex}:${c.content}')
          .toList();

      library.replaceChunks(publicationUuid, batch(0));

      final second = store
          .box<ObChunk>()
          .getAll()
          .map((c) => '${c.chunkIndex}:${c.content}')
          .toList();

      expect(second, first);
      expect(publications.byUuid(publicationUuid)!.chunkCount, 3);
    });

    test('an empty batch clears the chunk set', () {
      library.replaceChunks(publicationUuid, [draft(0), draft(1, seed: 1)]);
      library.replaceChunks(publicationUuid, const []);

      expect(store.box<ObChunk>().count(), 0);
      expect(publications.byUuid(publicationUuid)!.chunkCount, 0);
    });
  });
}

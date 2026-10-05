import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/data/embedding/embedder.dart';
import 'package:mylittlenotebooks/data/embedding/note_indexer.dart';
import 'package:mylittlenotebooks/data/embedding/text_chunker.dart';

void main() {
  TextChunker chunker({int maxTokens = 512, int overlap = 64}) =>
      HeadingAwareTextChunker(
        tokenizer: WhitespaceTokenizer(),
        maxTokens: maxTokens,
        overlap: overlap,
      );

  group('chunker (AC32)', () {
    test('an empty or whitespace-only body yields no chunks', () {
      expect(chunker().chunk(''), isEmpty);
      expect(chunker().chunk('   \n\t '), isEmpty);
    });

    test('a new chunk starts at each heading and is never merged', () {
      final chunks = chunker().chunk('# A\n\nalpha beta\n\n# B\n\ngamma');
      expect(chunks.map((c) => c.content).toList(),
          ['# A\n\nalpha beta', '# B\n\ngamma']);
      expect(chunks.map((c) => c.index).toList(), [0, 1]);
    });

    test('a large section splits into overlapping token windows', () {
      final body = List.generate(600, (i) => 'w$i').join(' ');
      final chunks = chunker(maxTokens: 100, overlap: 10).chunk(body);

      expect(chunks.length, greaterThan(1));
      expect(chunks.first.tokenCount, 100);
      for (var i = 0; i < chunks.length; i++) {
        expect(chunks[i].index, i);
      }
      // The second window starts one overlap after the first.
      expect(chunks[1].content.split(' ').first, 'w90');
    });
  });

  group('embedder (AC30, AC31)', () {
    test('applies the mandatory task prefixes', () async {
      final embedder = DeterministicEmbedder();
      await embedder.embedDocuments(['hello']);
      await embedder.embedQuery('hi');
      expect(embedder.received,
          ['search_document: hello', 'search_query: hi']);
    });

    test('vectors are 256-dim, finite, and unit norm', () async {
      final embedder = DeterministicEmbedder();
      final vector = (await embedder.embedDocuments(['x'])).single;
      expect(vector.length, 256);
      expect(vector.every((v) => v.isFinite), isTrue);
      final norm = sqrt(vector.fold<double>(0, (a, b) => a + b * b));
      expect(norm, closeTo(1.0, 1e-9));
    });
  });

  group('indexer (FR9, AC33)', () {
    test('an empty body calls the embedder zero times', () async {
      final embedder = DeterministicEmbedder();
      final indexer = NoteIndexer(chunker: chunker(), embedder: embedder);
      expect(await indexer.index(''), isEmpty);
      expect(await indexer.index('   '), isEmpty);
      expect(embedder.received, isEmpty);
    });

    test('a non-empty body yields one draft per chunk, embedded in one batch',
        () async {
      final embedder = DeterministicEmbedder();
      final indexer = NoteIndexer(chunker: chunker(), embedder: embedder);
      final drafts = await indexer.index('# A\n\nhello world\n\n# B\n\nmore');
      expect(drafts, hasLength(2));
      expect(drafts.length, embedder.received.length,
          reason: 'one embed call per chunk');
      for (var i = 0; i < drafts.length; i++) {
        expect(drafts[i].chunkIndex, i);
      }
    });
  });
}

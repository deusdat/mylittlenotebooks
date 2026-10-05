import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/data/embedding/onnx_embedder.dart';

/// The pure post-processing of the ONNX pipeline (spec FR8 steps 4–6, AC31),
/// tested without a model.
void main() {
  group('mean pooling', () {
    test('weights by the attention mask so padding does not contribute', () {
      final tokenVectors = [
        [1.0, 2.0],
        [3.0, 4.0],
        [100.0, 100.0], // padding, mask 0
      ];
      final pooled = meanPool(tokenVectors, [1, 1, 0]);
      expect(pooled, [2.0, 3.0]);
    });

    test('an all-masked sequence yields zeros, not NaN', () {
      expect(meanPool([
        [1.0, 2.0]
      ], [0]), [0.0, 0.0]);
    });
  });

  group('Matryoshka truncation', () {
    test('slices to the requested width', () {
      final vector = List<double>.generate(768, (i) => i.toDouble());
      final truncated = truncateToDimensions(vector, 256);
      expect(truncated.length, 256);
      expect(truncated.first, 0.0);
      expect(truncated.last, 255.0);
    });

    test('leaves a shorter vector unchanged', () {
      expect(truncateToDimensions([1.0, 2.0], 256), [1.0, 2.0]);
    });
  });

  group('L2 normalisation', () {
    test('produces a unit vector', () {
      final normalized = l2Normalize([3.0, 4.0]);
      expect(normalized[0], closeTo(0.6, 1e-12));
      expect(normalized[1], closeTo(0.8, 1e-12));
      final norm = sqrt(normalized.fold<double>(0, (a, b) => a + b * b));
      expect(norm, closeTo(1.0, 1e-12));
    });

    test('a zero vector is returned as-is, not NaN', () {
      expect(l2Normalize([0.0, 0.0]), [0.0, 0.0]);
    });
  });

  test('the nomic task prefixes are fixed (D18)', () {
    expect(OnnxEmbedder.documentPrefix, 'search_document: ');
    expect(OnnxEmbedder.queryPrefix, 'search_query: ');
  });
}

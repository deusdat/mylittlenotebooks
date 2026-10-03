import 'dart:convert';

import 'package:mylittlenotebooks/data/invalid_embedding_exception.dart';

/// The vector geometry. Single source of truth — these are never literals
/// elsewhere (spec FR7, D11).
abstract final class VectorGeometry {
  /// Must equal the HNSW index's `dimensions` in `ObChunk`.
  ///
  /// Changing it triggers a **full HNSW re-index**, so it changes together
  /// with the annotation and the model's truncation, never alone.
  static const int dimensions = 256;
}

/// Throws [InvalidEmbeddingException] unless [embedding] is storable.
///
/// Called on **every** write path, before `put` (spec FR8, plan R7).
///
/// Three distinct ways a vector can be unusable, all silent in the store:
///  1. Wrong length — ObjectBox indexes only up to `dimensions`, so a short
///     vector becomes invisible to search.
///  2. Non-finite values — `NaN` and `±inf` poison the HNSW graph and
///     silently degrade every subsequent query, not just the bad row.
///  3. Wrong element type — a `Float64List` would round-trip as float32
///     anyway, so accepting it silently loses precision.
void validateEmbedding(List<double> embedding) {
  if (embedding.length != VectorGeometry.dimensions) {
    throw InvalidEmbeddingException(
      actualLength: embedding.length,
      expectedLength: VectorGeometry.dimensions,
    );
  }
  for (var i = 0; i < embedding.length; i++) {
    final value = embedding[i];
    if (value.isNaN || value.isInfinite) {
      throw InvalidEmbeddingException(
        actualLength: embedding.length,
        expectedLength: VectorGeometry.dimensions,
      );
    }
  }
}

/// UTF-8 byte length of [text].
///
/// **Not** `text.length`, which counts UTF-16 code units. Any document
/// containing a non-ASCII character — an em dash, an accented letter, any
/// emoji — would report a smaller size than the bytes actually stored, and the
/// error scales with the document (spec D8, T11).
int utf8ByteLength(String text) => utf8.encode(text).length;

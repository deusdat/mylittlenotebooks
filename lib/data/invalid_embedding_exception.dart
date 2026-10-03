/// Thrown when a chunk's embedding cannot be stored (spec FR8).
///
/// A **dedicated** type rather than an `ArgumentError`, because at an ingestion
/// boundary the caller needs to distinguish "the model produced a malformed
/// vector" from every other bad argument. The chunker and the embedding
/// pipeline catch exactly this one case.
///
/// This error exists because ObjectBox's HNSW index **does not reject bad
/// vectors**. The index is declared with `dimensions: 256`, and a vector with
/// fewer dimensions is silently ignored: it stores without throwing, the chunk
/// appears in every listing and count, and it is simply unfindable by search
/// (spec plan R7, verified). Rejecting at the write boundary is the only place
/// that failure can still be caught.
class InvalidEmbeddingException implements Exception {
  /// The length the vector actually had.
  final int actualLength;

  /// The length the index requires.
  final int expectedLength;

  const InvalidEmbeddingException({
    required this.actualLength,
    required this.expectedLength,
  });

  @override
  String toString() =>
      'InvalidEmbeddingException: embedding has $actualLength dimensions, '
      'but the vector index requires exactly $expectedLength. ObjectBox would '
      'have stored this chunk and left it unfindable by search.';
}

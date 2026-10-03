import 'package:mylittlenotebooks/models/chunk.dart';

/// One retrieval hit: a chunk and how far it was from the query vector.
///
/// The field is named [distance], never `score`, because ObjectBox's `score`
/// **is a distance** where smaller means nearer (spec FR14). A field called
/// `score` invites the opposite comparison at the call site, which would
/// silently invert result ordering.
class SearchResult {
  final Chunk chunk;

  /// Distance from the query vector. **Smaller is nearer.**
  final double distance;

  const SearchResult({required this.chunk, required this.distance});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SearchResult &&
          other.chunk == chunk &&
          other.distance == distance;

  @override
  int get hashCode => Object.hash(chunk, distance);

  @override
  String toString() => 'SearchResult(#${chunk.chunkIndex}, d=$distance)';
}

import 'package:mylittlenotebooks/models/note_chunk.dart';

/// One note-scoped retrieval hit: a note chunk and how far it was from the
/// query vector (spec FR35).
///
/// Named [distance], never `score`, because ObjectBox's `score` **is a
/// distance** where smaller means nearer (mirrors `SearchResult`).
class NoteSearchResult {
  final NoteChunk chunk;

  /// Distance from the query vector. **Smaller is nearer.**
  final double distance;

  const NoteSearchResult({required this.chunk, required this.distance});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NoteSearchResult &&
          other.chunk == chunk &&
          other.distance == distance;

  @override
  int get hashCode => Object.hash(chunk, distance);

  @override
  String toString() => 'NoteSearchResult(#${chunk.chunkIndex}, d=$distance)';
}

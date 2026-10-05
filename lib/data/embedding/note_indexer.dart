import 'package:mylittlenotebooks/data/embedding/embedder.dart';
import 'package:mylittlenotebooks/data/embedding/text_chunker.dart';
import 'package:mylittlenotebooks/models/chunk.dart';

/// Orchestrates chunking and embedding for a note body (spec FR9).
///
/// Performs no write itself: it returns the drafts, and the caller hands them to
/// the atomic repository write. A failed embedding therefore leaves nothing to
/// roll back.
class NoteIndexer {
  NoteIndexer({required this.chunker, required this.embedder});

  final TextChunker chunker;
  final Embedder embedder;

  /// Chunks [body] and embeds each chunk. Returns an empty list — and calls the
  /// embedder **zero times** — when the body yields no chunks, which is what
  /// makes an empty note create no rows (spec FR9, AC4).
  Future<List<ChunkDraft>> index(String body) async {
    final chunks = chunker.chunk(body);
    if (chunks.isEmpty) return const [];

    final vectors = await embedder.embedDocuments(
      [for (final chunk in chunks) chunk.content],
    );

    return [
      for (var i = 0; i < chunks.length; i++)
        ChunkDraft(
          chunkIndex: chunks[i].index,
          content: chunks[i].content,
          tokenCount: chunks[i].tokenCount,
          embedding: vectors[i],
        ),
    ];
  }
}

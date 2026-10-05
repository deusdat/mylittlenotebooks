import 'package:mylittlenotebooks/data/embedding_validation.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_note.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_note_chunk.dart';
import 'package:mylittlenotebooks/data/search_repository.dart' show FetchBudget;
import 'package:mylittlenotebooks/domain_mapping.dart';
import 'package:mylittlenotebooks/models/note_search_result.dart';
import 'package:mylittlenotebooks/objectbox.g.dart';

/// Vector retrieval over one note's chunks (spec FR35).
///
/// The note analogue of `SearchRepository`. It takes the note's **uuid** and
/// resolves it internally, because the scope is always a single note rather
/// than a set.
abstract interface class NoteSearchRepository {
  /// The nearest chunks of [noteUuid] to [queryVector], ascending by distance,
  /// truncated to [limit].
  ///
  /// An unknown note, or a note with no chunks, returns empty.
  List<NoteSearchResult> search({
    required String noteUuid,
    required List<double> queryVector,
    required int limit,
    /// Test seam: bypass the computed over-fetch and use this candidate count,
    /// so a test can prove the naive `fetchCount == limit` under-delivers.
    int? fetchCountOverride,
  });
}

class ObjectBoxNoteSearchRepository implements NoteSearchRepository {
  ObjectBoxNoteSearchRepository(Store store)
      : _chunks = store.box<ObNoteChunk>(),
        _notes = store.box<ObNote>();

  final Box<ObNoteChunk> _chunks;
  final Box<ObNote> _notes;

  @override
  List<NoteSearchResult> search({
    required String noteUuid,
    required List<double> queryVector,
    required int limit,
    int? fetchCountOverride,
  }) {
    validateEmbedding(queryVector);
    if (limit <= 0) return const [];

    final note = _findNote(noteUuid);
    if (note == null) return const [];

    // `maxResultCount` bounds the ANN sub-query BEFORE the `noteId` filter, so
    // the candidate count must be over-fetched by scope selectivity — the same
    // bug `SearchRepository` documents (spec FR35, plan §H).
    final total = _chunks.count();
    final scopeCount = _countChunks(note.id);
    final fraction = total > 0 ? scopeCount / total : 1.0;
    final fetchCount = fetchCountOverride ??
        FetchBudget.forLimit(limit: limit, scopeFraction: fraction);

    final condition =
        ObNoteChunk_.embedding.nearestNeighborsF32(queryVector, fetchCount);
    final query = _chunks
        .query(condition.and(ObNoteChunk_.noteId.equals(note.id)))
        .build();

    try {
      final hits = query.findWithScores();
      // The ANN can return more than `limit` once the filter is applied;
      // truncate here because ObjectBox does not.
      return hits
          .take(limit)
          .map((hit) => NoteSearchResult(
                chunk: hit.object.toDomain(noteUuid: noteUuid),
                distance: hit.score,
              ))
          .toList();
    } finally {
      query.close();
    }
  }

  int _countChunks(int noteId) {
    final query = _chunks.query(ObNoteChunk_.noteId.equals(noteId)).build();
    try {
      return query.count();
    } finally {
      query.close();
    }
  }

  ObNote? _findNote(String uuid) {
    final query = _notes.query(ObNote_.uuid.equals(uuid)).build();
    try {
      return query.findFirst();
    } finally {
      query.close();
    }
  }
}

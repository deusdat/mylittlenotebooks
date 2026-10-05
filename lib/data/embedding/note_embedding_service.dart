import 'package:flutter/foundation.dart';
import 'package:mylittlenotebooks/data/embedding/note_indexer.dart';
import 'package:mylittlenotebooks/data/note_repository.dart';
import 'package:mylittlenotebooks/models/note.dart';

/// Background (re)embedding for notes (spec FR11a, D39).
///
/// Every unit of work is serialized onto one queue, so the single ONNX session
/// is never entered concurrently. Each note flips to
/// [NoteEmbeddingState.complete] in its own transaction, so progress survives a
/// crash between notes. A failure leaves the note `inProcess` (to be retried at
/// boot or on the next save) and never breaks the queue.
class NoteEmbeddingService {
  NoteEmbeddingService({required this.repo, required this.indexer});

  final NoteRepository repo;
  final NoteIndexer indexer;

  /// Bumped whenever a note reaches [NoteEmbeddingState.complete], so the editor
  /// can refresh its "not searchable" banner without polling.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  Future<void> _tail = Future.value();

  /// Completes when every queued embedding has finished. Test seam.
  Future<void> get idle => _tail;

  /// The model id written to completed notes — the embedder's own id, so there
  /// is one source of truth.
  String get activeModelId => indexer.embedder.modelId;

  /// Queues [uuid] for (re)embedding behind any in-flight work.
  Future<void> embed(String uuid) {
    final run = _tail.then((_) => _embedOne(uuid));
    _tail = run.catchError((Object error, StackTrace stack) {
      // The note stays `inProcess`; retried at boot or on the next save.
      debugPrint('[embedding] $uuid failed: $error');
    });
    return _tail;
  }

  /// (Re)embeds every note left [NoteEmbeddingState.inProcess] — the boot
  /// recovery for an interrupted save (spec FR11a).
  Future<void> recoverAll() async {
    for (final uuid in repo.inProcessNoteUuids()) {
      await embed(uuid);
    }
  }

  Future<void> _embedOne(String uuid) async {
    final note = repo.byUuid(uuid);
    if (note == null) return;
    if (note.embeddingState != NoteEmbeddingState.inProcess) return;

    final drafts = await indexer.index(note.body);
    repo.completeEmbedding(
      uuid,
      embeddingModelId: activeModelId,
      chunks: drafts,
    );
    revision.value++;
  }

  void dispose() => revision.dispose();
}

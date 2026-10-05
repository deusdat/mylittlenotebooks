import 'package:mylittlenotebooks/models/chunk.dart';
import 'package:mylittlenotebooks/models/note.dart';

/// Write and read side of notes (spec FR10–FR17).
///
/// **Synchronous**, matching `NotebookRepository` and `LibraryRepository`. The
/// body write and the chunk-set replacement for a body save share one
/// transaction, so a note is never observable with a new body and the old chunk
/// set (spec FR12).
abstract interface class NoteRepository {
  /// Creates a note in [notebookUuid] with an empty-or-initial body (spec FR10).
  ///
  /// The note starts with `chunkCount == 0`, `chunkSetVersion == 0`,
  /// `versionCounter == 1`, and `createdAt == updatedAt`. No embedder runs: an
  /// empty body has no chunks (spec FR9).
  Note create({
    String? title,
    required String notebookUuid,
    String embeddingModelId = '',
  });

  /// Writes metadata only — a title change (spec FR11).
  ///
  /// Bumps `versionCounter` and `updatedAt`; never touches the body, the chunk
  /// set, or `chunkSetVersion`. No embedding runs.
  void updateMetadata(String noteUuid, {required String? title});

  /// **Step 1 of a background save** (spec FR11a): durably writes the body and
  /// the title, marks [NoteEmbeddingState.inProcess], and removes the stale
  /// chunk set — all in one transaction, so a crash after this point loses no
  /// edit and leaves no half-searchable note. Boot recovery re-embeds it.
  void beginEmbedding(
    String noteUuid, {
    required String? title,
    required String body,
  });

  /// **Step 2 of a background save** (spec FR11a): validates and writes the
  /// freshly built chunk set, sets the producing model, and marks the note
  /// [NoteEmbeddingState.complete], in one transaction.
  void completeEmbedding(
    String noteUuid, {
    required String embeddingModelId,
    required List<ChunkDraft> chunks,
  });

  /// Writes the body and the entire chunk set in **one** transaction (spec
  /// FR12), marking the note complete. Used where the vectors are already known
  /// — the sync receive path and tests — rather than the two-step background
  /// save.
  ///
  /// Validates every draft with `validateEmbedding` before opening the
  /// transaction.
  void replaceBodyAndChunks(
    String noteUuid, {
    required String? title,
    required String body,
    required String embeddingModelId,
    required List<ChunkDraft> chunks,
  });

  /// Replaces **only** the chunk set (spec FR12), leaving the body and title
  /// untouched. Used by the sync receive path, which writes the body through
  /// the document row and the model label through metadata.
  ///
  /// Validates every draft before opening the transaction; bumps
  /// `chunkSetVersion` and `versionCounter`; updates `chunkCount`.
  void replaceChunks(String noteUuid, List<ChunkDraft> chunks);

  /// Attaches a note to a notebook. Idempotent (spec FR13).
  void attach(String noteUuid, String notebookUuid);

  /// Detaches. Idempotent (spec FR13).
  void detach(String noteUuid, String notebookUuid);

  /// Removes a note and its children — chunks, body, and chat messages
  /// (spec FR14). Never deletes a notebook.
  void deleteNote(String noteUuid);

  /// The full note **including its body**, for the editor (spec FR17).
  Note? byUuid(String uuid);

  /// Note metadata, **without any body**, ordered by `createdAt` (spec FR17,
  /// FR18, NFR4).
  List<NoteSummary> listForNotebook(String notebookUuid);

  /// The uuids of notes whose embeddings are pending or were interrupted
  /// (spec FR11a). Drives boot recovery. Local-only.
  List<String> inProcessNoteUuids();
}

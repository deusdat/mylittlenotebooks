import 'package:mylittlenotebooks/models/chunk.dart';
import 'package:mylittlenotebooks/models/publication.dart';

/// Thrown when a publication is created with no usable source text
/// (spec FR4).
///
/// Separate from [InvalidEmbeddingException] so an importer can tell "this
/// document is empty" from "the model produced a bad vector" and report the
/// right thing to the user.
class EmptySourceException implements Exception {
  const EmptySourceException();

  @override
  String toString() => 'EmptySourceException: sourceMarkdown is empty or '
      'whitespace only. A publication must store the document itself, since '
      'the file it came from is not guaranteed to stay readable (spec FR4).';
}

/// Write side of the library: creating publications, associating them with
/// notebooks, and replacing chunk sets.
///
/// **Synchronous**, matching `NotebookRepository`. `Box` is synchronous, and
/// the router's synchronous `redirect` guard depends on that staying true
/// (spec plan I6).
abstract interface class LibraryRepository {
  /// Creates a publication from its source text.
  ///
  /// Throws [EmptySourceException] for empty or whitespace-only
  /// [sourceMarkdown] — nothing is written (spec FR4, AC5).
  Publication create({
    required String title,
    required String sourceMarkdown,
    required String embeddingModelId,
  });

  /// Replaces a publication's entire chunk set atomically (spec FR10).
  ///
  /// Throws [InvalidEmbeddingException] if any draft's vector is the wrong
  /// length, **before** anything is written (spec FR8).
  void replaceChunks(String publicationUuid, List<ChunkDraft> chunks);

  /// Removes a publication and its chunks. Notebooks survive, holding one
  /// fewer publication each (spec FR12).
  void deletePublication(String publicationUuid);

  /// Attaches a publication to a notebook. Idempotent (spec FR11).
  void attach(String publicationUuid, String notebookUuid);

  /// Detaches. Idempotent (spec FR11).
  void detach(String publicationUuid, String notebookUuid);

  /// Removes a notebook's **associations only**.
  ///
  /// Never deletes publications or chunks: they may be attached to other
  /// notebooks, and a shared publication deleted here would be data loss the
  /// user cannot undo (spec FR12, plan R9).
  void deleteNotebook(String notebookUuid);
}

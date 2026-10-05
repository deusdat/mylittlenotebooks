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

/// A publication that a notebook delete cascaded away.
///
/// Carries only row data captured **before** the row was removed: the uuid and
/// the version the publication died at. The delete-notebook feature needs both
/// to write a tombstone, and neither is a sync concept — a uuid is an entity
/// identity and the counter is already a column on `ObPublication`.
class CascadedPublication {
  final String uuid;

  /// The publication's `versionCounter` as it stood before the cascade. The
  /// sync layer turns this into a death version with `nextVersion`.
  final int versionCounter;

  const CascadedPublication({
    required this.uuid,
    required this.versionCounter,
  });
}

/// A note that a notebook delete cascaded away (spec FR15). Mirrors
/// [CascadedPublication].
class CascadedNote {
  final String uuid;

  /// The note's `versionCounter` as it stood before the cascade.
  final int versionCounter;

  const CascadedNote({required this.uuid, required this.versionCounter});
}

/// Everything a notebook delete removed: exclusive publications and exclusive
/// notes (spec FR15).
///
/// A single return value so `SyncDeleter` has one call site and one place to
/// write tombstones for both child kinds.
class NotebookCascade {
  final List<CascadedPublication> publications;
  final List<CascadedNote> notes;

  const NotebookCascade({
    this.publications = const [],
    this.notes = const [],
  });
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

  /// Removes a notebook and every publication that exists **only** inside it.
  ///
  /// A publication attached to any other notebook is a **shared** publication
  /// and is never deleted: its edge to this notebook goes away with the
  /// notebook, but the publication, its document, and its chunks survive and
  /// stay reachable from the other notebook (spec FR1, FR3).
  ///
  /// Exclusivity is resolved here, at delete time, from the notebook's own
  /// edges — never cached (spec FR2). Returns the cascaded publications **and
  /// notes** so the caller can write tombstones. This **amends** the data-layer
  /// spec's FR12 and this feature's FR15; see the amendment record.
  NotebookCascade deleteNotebook(String notebookUuid);
}

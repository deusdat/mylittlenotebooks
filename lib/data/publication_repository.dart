import 'package:mylittlenotebooks/models/publication.dart';

/// Read access to publications and the notebook↔publication association
/// (spec FR1, FR5).
///
/// The association is many-to-many in both directions, and both directions are
/// part of this interface on purpose: a test that reads only one side passes
/// against a broken relation (spec AC2).
abstract interface class PublicationRepository {
  /// Publications attached to [notebookUuid], read through the `ToMany` on the
  /// notebook side.
  ///
  /// Returns summaries, not full aggregates: a list must never read the source
  /// documents (spec NFR6).
  List<PublicationSummary> listForNotebook(String notebookUuid);

  /// The publication with this uuid **including its source text**, or null.
  ///
  /// The only read that touches the document row (spec NFR6).
  Publication? byUuid(String uuid);

  /// uuids of the notebooks this publication is attached to, read through the
  /// `@Backlink` side.
  List<String> attachments(String publicationUuid);

  /// Every publication in the store, oldest import first, as summaries.
  List<PublicationSummary> listAll();

  /// The distinct embedding model ids in use (spec FR6).
  ///
  /// More than one value means a model change happened without a re-index, and
  /// vectors across the two are not comparable. This is what makes that
  /// detectable rather than silent.
  List<String> embeddingModelIds();

  /// Publications indexed under [embeddingModelId] — the set that needs
  /// re-indexing when the model changes (spec FR6). As summaries.
  List<PublicationSummary> byEmbeddingModel(String embeddingModelId);
}

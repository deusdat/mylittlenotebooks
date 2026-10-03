import 'package:mylittlenotebooks/data/embedding_validation.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_document.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_notebook.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_publication.dart';
import 'package:mylittlenotebooks/data/publication_repository.dart';
import 'package:mylittlenotebooks/domain_mapping.dart';
import 'package:mylittlenotebooks/models/publication.dart';
import 'package:mylittlenotebooks/objectbox.g.dart';

/// ObjectBox-backed [PublicationRepository].
///
/// Every method takes uuid, never an int id — the storage ids stop here
/// (spec FR5). The vector path is the one place that wants ids, and
/// `SearchRepository` resolves them itself.
///
/// **The list methods return [PublicationSummary], not [Publication].** ObjectBox
/// loads whole objects, so returning the aggregate would read every document in
/// the store to render a list of titles. The source text is fetched only by
/// [byUuid], which is the one method that genuinely needs it (spec NFR6).
class ObjectBoxPublicationRepository implements PublicationRepository {
  ObjectBoxPublicationRepository(this._store)
      : _box = _store.box<ObPublication>();

  final Store _store;
  final Box<ObPublication> _box;
  late final Box<ObNotebook> _notebooks = _store.box<ObNotebook>();
  late final Box<ObDocument> _documents = _store.box<ObDocument>();

  @override
  List<PublicationSummary> listForNotebook(String notebookUuid) {
    // One indexed lookup for the notebook, then its `ToMany` — a single lazy
    // relation load. Reading the backlink from every publication instead would
    // be an N+1 query per row (spec NFR6).
    final query = _notebooks.query(ObNotebook_.uuid.equals(notebookUuid)).build();
    try {
      final notebook = query.findFirst();
      if (notebook == null) return const [];
      final attached = notebook.publications.toList()
        ..sort((a, b) => a.importedAt.compareTo(b.importedAt));
      return List.unmodifiable(attached.map((p) => p.toSummary()));
    } finally {
      query.close();
    }
  }

  @override
  Publication? byUuid(String uuid) {
    final entity = _entityByUuid(uuid);
    if (entity == null) return null;
    return entity.toDomain(sourceMarkdown: _markdownFor(entity.id));
  }

  @override
  List<String> attachments(String publicationUuid) {
    final publication = _entityByUuid(publicationUuid);
    if (publication == null) return const [];
    return publication.notebooks.map((n) => n.uuid).toList();
  }

  @override
  List<PublicationSummary> listAll() {
    final query = _box.query().order(ObPublication_.importedAt).build();
    try {
      return query.find().map((p) => p.toSummary()).toList();
    } finally {
      query.close();
    }
  }

  @override
  List<String> embeddingModelIds() {
    final ids = <String>{};
    final query = _box.query().build();
    try {
      for (final publication in query.find()) {
        ids.add(publication.embeddingModelId);
      }
    } finally {
      query.close();
    }
    return ids.toList()..sort();
  }

  @override
  List<PublicationSummary> byEmbeddingModel(String embeddingModelId) {
    final query = _box
        .query(ObPublication_.embeddingModelId.equals(embeddingModelId))
        .order(ObPublication_.importedAt)
        .build();
    try {
      return query.find().map((p) => p.toSummary()).toList();
    } finally {
      query.close();
    }
  }

  ObPublication? _entityByUuid(String uuid) {
    final query = _box.query(ObPublication_.uuid.equals(uuid)).build();
    try {
      return query.findFirst();
    } finally {
      query.close();
    }
  }

  /// The document text, read on demand and only here.
  String _markdownFor(int publicationId) {
    final query = _documents
        .query(ObDocument_.publicationId.equals(publicationId))
        .build();
    try {
      return documentMarkdownOf(query.findFirst()) ?? '';
    } finally {
      query.close();
    }
  }

  /// Byte length of a publication's source text, exposed so the create path and
  /// its tests agree on one definition (spec D8).
  static int byteSizeOf(String sourceMarkdown) =>
      utf8ByteLength(sourceMarkdown);
}

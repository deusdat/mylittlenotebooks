import 'package:mylittlenotebooks/data/identity.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_ai_config.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_chunk.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_document.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_notebook.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_publication.dart';
import 'package:mylittlenotebooks/models/ai_endpoint_config.dart';
import 'package:mylittlenotebooks/models/chunk.dart';
import 'package:mylittlenotebooks/models/notebook.dart';
import 'package:mylittlenotebooks/models/publication.dart';

/// Every conversion between a storage entity and its domain value.
///
/// This is the only place such a conversion is written (spec NFR5, plan §E).
/// A conversion appearing inside a repository is a layering leak: it would
/// make the entity types reachable from callers, and would put the int
/// storage ids into the domain where they do not belong (spec FR5).
///
/// The asymmetry is deliberate. `ObChunk.publicationId` is an int and is
/// resolved to the publication's uuid by the repository, which is the layer
/// that knows both sides. Nothing here invents a uuid.

// --- Notebook ---------------------------------------------------------------

// The domain `Notebook.id` is the application-level opaque string the shell
// already uses; `ObNotebook.uuid` is the same value under its storage name
// (spec FR5, D14). Renaming the domain field would ripple through the router,
// the state layer, and seven passing tests for no gain.

extension ObNotebookMapping on ObNotebook {
  Notebook toDomain() =>
      Notebook(id: uuid, title: title, createdAt: createdAt);
}

extension NotebookMapping on Notebook {
  ObNotebook toEntity() =>
      ObNotebook(uuid: id, title: title, createdAt: createdAt);
}

// --- Publication ------------------------------------------------------------

extension ObPublicationMapping on ObPublication {
  /// The full aggregate, including the source text.
  ///
  /// Loads the document row. Use only where the text is genuinely needed —
  /// preview, re-chunk, citation (spec NFR6).
  Publication toDomain({String sourceMarkdown = ''}) => Publication(
        uuid: uuid,
        title: title,
        sourceMarkdown: sourceMarkdown,
        byteSize: byteSize,
        importedAt: importedAt,
        embeddingModelId: embeddingModelId,
        chunkCount: chunkCount,
      );

  /// The metadata only. **This is what list and search paths use**, so they
  /// never read the document row (spec NFR6).
  PublicationSummary toSummary() => PublicationSummary(
        uuid: uuid,
        title: title,
        byteSize: byteSize,
        importedAt: importedAt,
        embeddingModelId: embeddingModelId,
        chunkCount: chunkCount,
      );
}

extension PublicationMapping on Publication {
  /// [Publication] has no int id, so a fresh entity is produced and the caller
  /// assigns the real one from the id a `put` returns.
  ObPublication toEntity() => ObPublication(
        uuid: uuid,
        title: title,
        byteSize: byteSize,
        importedAt: importedAt,
        embeddingModelId: embeddingModelId,
        chunkCount: chunkCount,
      );
}

// --- Chunk ------------------------------------------------------------------

extension ObChunkMapping on ObChunk {
  /// Requires [publicationUuid] because the entity holds only the int id
  /// (spec FR5, FR7).
  Chunk toDomain({required String publicationUuid}) => Chunk(
        publicationUuid: publicationUuid,
        chunkIndex: chunkIndex,
        content: content,
        tokenCount: tokenCount,
        embedding: embedding,
      );
}

extension ChunkDraftMapping on ChunkDraft {
  /// Writes **both** representations of the publication reference in one go —
  /// the indexed [ObChunk.publicationId] column and the [ObChunk.publication]
  /// relation — because the two must never diverge (spec FR7, FR10, plan R6).
  ///
  /// Takes the publication's **uuid** as well as its local int: a chunk's uuid
  /// is *derived* from `(publicationUuid, chunkIndex)` (peer-sync FR2a), so it
  /// needs the portable identifier, not the device-local one.
  ObChunk toEntity({required int publicationId, required String publicationUuid}) {
    final entity = ObChunk(
      uuid: chunkUuidFor(publicationUuid, chunkIndex),
      chunkIndex: chunkIndex,
      content: content,
      tokenCount: tokenCount,
      publicationId: publicationId,
      embedding: embedding,
    );
    entity.publication.targetId = publicationId;
    return entity;
  }
}

// --- Document ---------------------------------------------------------------

/// Reads the source text for a publication, or null when it has none.
///
/// A separate read so the text is fetched on demand and never as a side effect
/// of listing publications (spec NFR6).
String? documentMarkdownOf(ObDocument? document) => document?.markdown;

// --- AI endpoint configuration ----------------------------------------------

extension ObAiConfigMapping on ObAiConfig {
  /// [hasToken] is supplied by the repository from its token-flag cache rather
  /// than read here: the mapping is pure and must not reach the secret store
  /// (settings-for-ai FR4, FR5).
  AiEndpointConfig toDomain({required bool hasToken}) => AiEndpointConfig(
        uuid: uuid,
        label: label,
        endpoint: endpoint,
        shared: shared,
        hasToken: hasToken,
      );
}

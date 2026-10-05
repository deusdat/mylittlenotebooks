import 'package:mylittlenotebooks/data/identity.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_ai_config.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_chat_message.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_chunk.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_document.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_note.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_note_chunk.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_note_document.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_notebook.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_publication.dart';
import 'package:mylittlenotebooks/models/ai_endpoint_config.dart';
import 'package:mylittlenotebooks/models/chat_message.dart';
import 'package:mylittlenotebooks/models/chunk.dart';
import 'package:mylittlenotebooks/models/note.dart';
import 'package:mylittlenotebooks/models/note_chunk.dart';
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

// --- Note -------------------------------------------------------------------

extension ObNoteMapping on ObNote {
  /// The full aggregate, including the body. Loads the document row, so use it
  /// only where the body is genuinely needed — the editor (spec FR17).
  Note toDomain({String body = ''}) => Note(
        uuid: uuid,
        title: title,
        body: body,
        createdAt: createdAt,
        updatedAt: updatedAt,
        embeddingModelId: embeddingModelId,
        chunkCount: chunkCount,
        embeddingState: NoteEmbeddingState.fromStorage(embeddingState),
      );

  /// The metadata only. **This is what list paths use**, so they never read the
  /// document row (spec NFR4, FR17).
  NoteSummary toSummary() => NoteSummary(
        uuid: uuid,
        title: title,
        createdAt: createdAt,
        updatedAt: updatedAt,
        embeddingModelId: embeddingModelId,
        chunkCount: chunkCount,
        embeddingState: NoteEmbeddingState.fromStorage(embeddingState),
      );
}

extension NoteMapping on Note {
  ObNote toEntity() => ObNote(
        uuid: uuid,
        title: title,
        createdAt: createdAt,
        updatedAt: updatedAt,
        embeddingModelId: embeddingModelId,
        chunkCount: chunkCount,
        embeddingState: embeddingState.storage,
      );
}

/// The body behind a note, or null when it has none. A separate read so the body
/// is fetched on demand and never as a side effect of listing notes (spec NFR4).
String? noteBodyOf(ObNoteDocument? document) => document?.markdown;

extension ObNoteChunkMapping on ObNoteChunk {
  /// Requires [noteUuid] because the entity holds only the int id (spec FR5).
  NoteChunk toDomain({required String noteUuid}) => NoteChunk(
        noteUuid: noteUuid,
        chunkIndex: chunkIndex,
        content: content,
        tokenCount: tokenCount,
        embedding: embedding,
      );
}

extension NoteChunkDraftMapping on ChunkDraft {
  /// Writes **both** representations of the note reference in one go — the
  /// indexed [ObNoteChunk.noteId] column and the [ObNoteChunk.note] relation —
  /// so they cannot drift (spec FR12, FR21).
  ObNoteChunk toNoteChunkEntity({
    required int noteId,
    required String noteUuid,
  }) {
    final entity = ObNoteChunk(
      uuid: noteChunkUuidFor(noteUuid, chunkIndex),
      chunkIndex: chunkIndex,
      content: content,
      tokenCount: tokenCount,
      noteId: noteId,
      embedding: embedding,
    );
    entity.note.targetId = noteId;
    return entity;
  }
}

// --- Chat message -----------------------------------------------------------

/// Storage form of a role. Stored as a stable string, never an ordinal.
String chatRoleToStorage(ChatMessageRole role) => role.name;

/// Parses a stored role, defaulting unknown values to `user` rather than
/// throwing: a message's role must never make a list read fail.
ChatMessageRole chatRoleFromStorage(String role) =>
    role == 'assistant' ? ChatMessageRole.assistant : ChatMessageRole.user;

extension ObChatMessageMapping on ObChatMessage {
  ChatMessage toDomain({required String noteUuid}) => ChatMessage(
        uuid: uuid,
        noteUuid: noteUuid,
        role: chatRoleFromStorage(role),
        text: text,
        createdAt: createdAt,
      );
}

extension ChatMessageMapping on ChatMessage {
  ObChatMessage toEntity({required int noteId}) => ObChatMessage(
        uuid: uuid,
        noteId: noteId,
        role: chatRoleToStorage(role),
        text: text,
        createdAt: createdAt,
      );
}

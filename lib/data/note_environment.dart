import 'package:mylittlenotebooks/data/chat_message_repository.dart';
import 'package:mylittlenotebooks/data/embedding/note_embedding_service.dart';
import 'package:mylittlenotebooks/data/note_repository.dart';

/// The note dependencies the UI needs, bundled so they can be threaded through
/// the shell and router as one constructor argument (no service locator).
class NoteEnvironment {
  final NoteRepository notes;
  final ChatMessageRepository chatMessages;

  /// Background embedding (spec FR11a). Owns the indexer and exposes the active
  /// model id and a revision notifier the editor listens to.
  final NoteEmbeddingService embedding;

  const NoteEnvironment({
    required this.notes,
    required this.chatMessages,
    required this.embedding,
  });

  /// This device's active embedding model id.
  String get activeModelId => embedding.activeModelId;
}

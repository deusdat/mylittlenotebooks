import 'package:mylittlenotebooks/data/embedding/embedder.dart';
import 'package:mylittlenotebooks/data/embedding/note_embedding_service.dart';
import 'package:mylittlenotebooks/data/embedding/note_indexer.dart';
import 'package:mylittlenotebooks/data/embedding/text_chunker.dart';
import 'package:mylittlenotebooks/data/in_memory_chat_message_repository.dart';
import 'package:mylittlenotebooks/data/in_memory_note_repository.dart';
import 'package:mylittlenotebooks/data/note_environment.dart';

/// A [NoteEnvironment] backed by in-memory repositories and the pre-M6 fakes,
/// for widget and state tests that must not open a store.
NoteEnvironment testNoteEnvironment() {
  final notes = InMemoryNoteRepository();
  final indexer = NoteIndexer(
    chunker: HeadingAwareTextChunker(tokenizer: WhitespaceTokenizer()),
    embedder: DeterministicEmbedder(),
  );
  return NoteEnvironment(
    notes: notes,
    chatMessages: InMemoryChatMessageRepository(),
    embedding: NoteEmbeddingService(repo: notes, indexer: indexer),
  );
}

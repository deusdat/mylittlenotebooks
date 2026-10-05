import 'package:mylittlenotebooks/models/chat_message.dart';

/// Read/write access to a note's local chat messages (spec FR34).
///
/// Local-only: messages are never selected into `SyncPayload` (spec D31).
abstract interface class ChatMessageRepository {
  /// The note's messages, ordered by `createdAt` ascending.
  List<ChatMessage> listForNote(String noteUuid);

  /// Appends a message. Not called by the UI in this feature (FR33).
  void append(ChatMessage message);
}

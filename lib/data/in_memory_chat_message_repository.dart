import 'package:mylittlenotebooks/data/chat_message_repository.dart';
import 'package:mylittlenotebooks/models/chat_message.dart';

/// In-memory [ChatMessageRepository] for hook and widget tests (spec plan §F).
class InMemoryChatMessageRepository implements ChatMessageRepository {
  final List<ChatMessage> _messages = [];

  @override
  List<ChatMessage> listForNote(String noteUuid) {
    final result = _messages.where((m) => m.noteUuid == noteUuid).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return result;
  }

  @override
  void append(ChatMessage message) => _messages.add(message);
}

import 'package:mylittlenotebooks/data/chat_message_repository.dart';
import 'package:mylittlenotebooks/data/identity.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_chat_message.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_note.dart';
import 'package:mylittlenotebooks/domain_mapping.dart';
import 'package:mylittlenotebooks/models/chat_message.dart';
import 'package:mylittlenotebooks/objectbox.g.dart';

/// ObjectBox-backed [ChatMessageRepository] (spec FR34).
class ObjectBoxChatMessageRepository implements ChatMessageRepository {
  ObjectBoxChatMessageRepository(this._store)
      : _messages = _store.box<ObChatMessage>(),
        _notes = _store.box<ObNote>();

  final Store _store;
  final Box<ObChatMessage> _messages;
  final Box<ObNote> _notes;

  @override
  List<ChatMessage> listForNote(String noteUuid) {
    final note = _findNote(noteUuid);
    if (note == null) return const [];

    final query = _messages
        .query(ObChatMessage_.noteId.equals(note.id))
        .order(ObChatMessage_.createdAt)
        .build();
    try {
      return query
          .find()
          .map((m) => m.toDomain(noteUuid: noteUuid))
          .toList();
    } finally {
      query.close();
    }
  }

  @override
  void append(ChatMessage message) {
    final note = _findNote(message.noteUuid);
    if (note == null) {
      throw StateError('no note with uuid ${message.noteUuid}');
    }
    _store.runInTransaction(TxMode.write, () {
      final entity = ObChatMessage(
        uuid: message.uuid.isEmpty ? newUuidV7() : message.uuid,
        noteId: note.id,
        role: chatRoleToStorage(message.role),
        text: message.text,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          message.createdAt.toUtc().millisecondsSinceEpoch,
          isUtc: true,
        ),
      );
      entity.note.targetId = note.id;
      _messages.put(entity);
    });
  }

  ObNote? _findNote(String uuid) {
    final query = _notes.query(ObNote_.uuid.equals(uuid)).build();
    try {
      return query.findFirst();
    } finally {
      query.close();
    }
  }
}

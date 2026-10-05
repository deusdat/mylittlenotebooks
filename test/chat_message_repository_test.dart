import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/data/chat_message_repository.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_chat_message.dart';
import 'package:mylittlenotebooks/data/objectbox/objectbox_store.dart';
import 'package:mylittlenotebooks/data/objectbox_chat_message_repository.dart';
import 'package:mylittlenotebooks/data/objectbox_note_repository.dart';
import 'package:mylittlenotebooks/data/objectbox_notebook_repository.dart';
import 'package:mylittlenotebooks/data/sync/sync_codec.dart';
import 'package:mylittlenotebooks/data/sync/sync_payload.dart';
import 'package:mylittlenotebooks/models/chat_message.dart';
import 'package:mylittlenotebooks/objectbox.g.dart';

void main() {
  late Store store;
  late ObjectBoxNoteRepository notes;
  late ChatMessageRepository messages;

  setUp(() {
    store = openTestStore('chat-msg');
    notes = ObjectBoxNoteRepository(store);
    messages = ObjectBoxChatMessageRepository(store);
  });

  tearDown(() => store.close());

  test('messages list in createdAt order (AC35)', () {
    final notebook = ObjectBoxNotebookRepository(store).create();
    final note = notes.create(notebookUuid: notebook.id);

    final base = DateTime.utc(2026, 1, 1, 12);
    messages
      ..append(ChatMessage(
        uuid: 'm2',
        noteUuid: note.uuid,
        role: ChatMessageRole.assistant,
        text: 'second',
        createdAt: base.add(const Duration(minutes: 1)),
      ))
      ..append(ChatMessage(
        uuid: 'm1',
        noteUuid: note.uuid,
        role: ChatMessageRole.user,
        text: 'first',
        createdAt: base,
      ));

    final list = messages.listForNote(note.uuid);
    expect(list.map((m) => m.text).toList(), ['first', 'second']);
    expect(list.first.role, ChatMessageRole.user);
  });

  test('deleting a note cascades its messages (AC35)', () {
    final notebook = ObjectBoxNotebookRepository(store).create();
    final note = notes.create(notebookUuid: notebook.id);
    messages.append(ChatMessage(
      uuid: 'm1',
      noteUuid: note.uuid,
      role: ChatMessageRole.user,
      text: 'hi',
      createdAt: DateTime.now().toUtc(),
    ));

    notes.deleteNote(note.uuid);

    expect(store.box<ObChatMessage>().count(), 0);
  });

  test('messages never appear in an encoded SyncPayload (AC35)', () {
    final payload = SyncPayload(publications: const [], deletes: const []);
    final encoded = encodePayload(payload);
    expect(encoded.contains('chat'), isFalse);
    expect(encoded.contains('message'), isFalse);
  });
}

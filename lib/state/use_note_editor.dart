import 'dart:async';

import 'package:mylittlenotebooks/data/embedding/note_embedding_service.dart';
import 'package:mylittlenotebooks/data/note_repository.dart';
import 'package:mylittlenotebooks/models/note.dart';
import 'package:mylittlenotebooks/state/note_editor_state.dart';
import 'package:utopia_hooks/utopia_hooks.dart';

/// The note editor's logic (spec FR28–FR30, FR11a).
///
/// [note] is null in new-note mode; the note is created on the first save. Dirty
/// is exact string inequality against the last saved values.
///
/// **Save is instant** (spec D39): the body is durably written and the note
/// marked in-process, then embedding runs in the background. A crash after
/// Save loses no edit; boot recovery re-embeds it.
NoteEditorState useNoteEditor({
  required Note? note,
  required String notebookId,
  required NoteRepository repo,
  required NoteEmbeddingService embedding,
  required String activeModelId,
  void Function(String uuid)? onSaved,
}) {
  final title = useState(note?.title ?? '');
  final body = useState(note?.body ?? '');
  final savedTitle = useState(note?.title ?? '');
  final savedBody = useState(note?.body ?? '');
  final saving = useState(false);
  final error = useState<String?>(null);

  final dirty =
      title.value != savedTitle.value || body.value != savedBody.value;

  final isUnindexed = note == null
      ? false
      : note.embeddingState == NoteEmbeddingState.inProcess ||
          (note.chunkCount == 0 && note.body.trim().isNotEmpty) ||
          (note.embeddingModelId.isNotEmpty &&
              note.embeddingModelId != activeModelId);

  Future<void> save() async {
    if (!dirty) return;

    final titleChanged = title.value != savedTitle.value;
    final bodyChanged = body.value != savedBody.value;
    // An empty title is "untitled" (spec FR18).
    final normalizedTitle = title.value.trim().isEmpty ? null : title.value;

    saving.setIfMounted(true);
    error.setIfMounted(null);
    try {
      final uuid = note?.uuid ??
          repo.create(notebookUuid: notebookId, title: normalizedTitle).uuid;

      if (bodyChanged) {
        // Durable body + in-process mark, then background embedding. The write
        // is synchronous and crash-safe; the embedding is not awaited.
        repo.beginEmbedding(uuid, title: normalizedTitle, body: body.value);
        unawaited(embedding.embed(uuid));
      } else if (note != null && titleChanged) {
        repo.updateMetadata(uuid, title: normalizedTitle);
      }

      savedTitle.setIfMounted(normalizedTitle ?? '');
      savedBody.setIfMounted(body.value);
      onSaved?.call(uuid);
    } catch (e) {
      error.setIfMounted('Could not save the note: $e');
    } finally {
      saving.setIfMounted(false);
    }
  }

  void cancel() {
    title.setIfMounted(savedTitle.value);
    body.setIfMounted(savedBody.value);
    error.setIfMounted(null);
  }

  return NoteEditorState(
    title: title.value,
    body: body.value,
    dirty: dirty,
    saving: saving.value,
    isUnindexed: isUnindexed,
    error: error.value,
    setTitle: (value) => title.setIfMounted(value),
    setBody: (value) => body.setIfMounted(value),
    save: save,
    cancel: cancel,
  );
}

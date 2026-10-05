import 'package:mylittlenotebooks/data/identity.dart';
import 'package:mylittlenotebooks/data/note_repository.dart';
import 'package:mylittlenotebooks/models/chunk.dart';
import 'package:mylittlenotebooks/models/note.dart';

/// In-memory [NoteRepository] for hook and widget tests (spec plan §F).
///
/// Substitutes for the durable repository the way `InMemoryNotebookRepository`
/// does, so the UI layer is testable with no store and no native library.
class InMemoryNoteRepository implements NoteRepository {
  final Map<String, Note> _notes = {};

  /// note uuid -> notebook uuids.
  final Map<String, Set<String>> _attachments = {};

  @override
  Note create({
    String? title,
    required String notebookUuid,
    String embeddingModelId = '',
  }) {
    final now = DateTime.fromMillisecondsSinceEpoch(
      DateTime.now().toUtc().millisecondsSinceEpoch,
      isUtc: true,
    );
    final note = Note(
      uuid: newUuidV7(),
      title: title,
      body: '',
      createdAt: now,
      updatedAt: now,
      embeddingModelId: '',
    );
    _notes[note.uuid] = note;
    _attachments[note.uuid] = {notebookUuid};
    return note;
  }

  @override
  void updateMetadata(String noteUuid, {required String? title}) {
    final note = _require(noteUuid);
    _notes[noteUuid] = Note(
      uuid: note.uuid,
      title: title,
      body: note.body,
      createdAt: note.createdAt,
      updatedAt: _now(),
      embeddingModelId: note.embeddingModelId,
      chunkCount: note.chunkCount,
    );
  }

  @override
  void replaceBodyAndChunks(
    String noteUuid, {
    required String? title,
    required String body,
    required String embeddingModelId,
    required List<ChunkDraft> chunks,
  }) {
    final note = _require(noteUuid);
    _notes[noteUuid] = Note(
      uuid: noteUuid,
      title: title,
      body: body,
      createdAt: note.createdAt,
      updatedAt: _now(),
      embeddingModelId: embeddingModelId,
      chunkCount: chunks.length,
    );
  }

  @override
  void beginEmbedding(
    String noteUuid, {
    required String? title,
    required String body,
  }) {
    final note = _require(noteUuid);
    _notes[noteUuid] = Note(
      uuid: note.uuid,
      title: title,
      body: body,
      createdAt: note.createdAt,
      updatedAt: _now(),
      embeddingModelId: note.embeddingModelId,
      chunkCount: 0,
      embeddingState: NoteEmbeddingState.inProcess,
    );
  }

  @override
  void completeEmbedding(
    String noteUuid, {
    required String embeddingModelId,
    required List<ChunkDraft> chunks,
  }) {
    final note = _require(noteUuid);
    _notes[noteUuid] = Note(
      uuid: note.uuid,
      title: note.title,
      body: note.body,
      createdAt: note.createdAt,
      updatedAt: _now(),
      embeddingModelId: embeddingModelId,
      chunkCount: chunks.length,
      embeddingState: NoteEmbeddingState.complete,
    );
  }

  @override
  void replaceChunks(String noteUuid, List<ChunkDraft> chunks) {
    final note = _require(noteUuid);
    _notes[noteUuid] = Note(
      uuid: note.uuid,
      title: note.title,
      body: note.body,
      createdAt: note.createdAt,
      updatedAt: _now(),
      embeddingModelId: note.embeddingModelId,
      chunkCount: chunks.length,
    );
  }

  @override
  void attach(String noteUuid, String notebookUuid) {
    _require(noteUuid);
    _attachments.putIfAbsent(noteUuid, () => {}).add(notebookUuid);
  }

  @override
  void detach(String noteUuid, String notebookUuid) {
    _require(noteUuid);
    _attachments[noteUuid]?.remove(notebookUuid);
  }

  @override
  void deleteNote(String noteUuid) {
    _notes.remove(noteUuid);
    _attachments.remove(noteUuid);
  }

  @override
  Note? byUuid(String uuid) => _notes[uuid];

  @override
  List<NoteSummary> listForNotebook(String notebookUuid) {
    final result = <NoteSummary>[];
    for (final entry in _notes.entries) {
      if (!(_attachments[entry.key]?.contains(notebookUuid) ?? false)) continue;
      final note = entry.value;
      result.add(NoteSummary(
        uuid: note.uuid,
        title: note.title,
        createdAt: note.createdAt,
        updatedAt: note.updatedAt,
        embeddingModelId: note.embeddingModelId,
        chunkCount: note.chunkCount,
      ));
    }
    result.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return result;
  }

  @override
  List<String> inProcessNoteUuids() => [
        for (final entry in _notes.entries)
          if (entry.value.embeddingState == NoteEmbeddingState.inProcess)
            entry.key,
      ];

  Note _require(String noteUuid) {
    final note = _notes[noteUuid];
    if (note == null) throw StateError('no note with uuid $noteUuid');
    return note;
  }

  static DateTime _now() => DateTime.fromMillisecondsSinceEpoch(
        DateTime.now().toUtc().millisecondsSinceEpoch,
        isUtc: true,
      );
}

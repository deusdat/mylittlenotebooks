import 'package:mylittlenotebooks/data/note_repository.dart';
import 'package:mylittlenotebooks/state/notes_list_state.dart';
import 'package:utopia_hooks/utopia_hooks.dart';

/// Builds [NotesListState] for one notebook (spec FR26).
///
/// Page-scoped: no global provider, the repository is constructor-injected into
/// the calling widget.
NotesListState useNotesList({
  required String notebookId,
  required NoteRepository repo,
}) {
  final notes = useState(repo.listForNotebook(notebookId));

  void refresh() {
    notes.value = repo.listForNotebook(notebookId);
  }

  String create() {
    final note = repo.create(notebookUuid: notebookId);
    refresh();
    return note.uuid;
  }

  return NotesListState(notes: notes.value, refresh: refresh, create: create);
}

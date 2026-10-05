import 'package:mylittlenotebooks/models/note.dart';

/// A notebook's note list (spec FR26).
class NotesListState {
  final List<NoteSummary> notes;

  /// Re-reads the list from the repository.
  final void Function() refresh;

  /// Creates a note in this notebook and returns its uuid (spec FR30).
  final String Function() create;

  const NotesListState({
    required this.notes,
    required this.refresh,
    required this.create,
  });
}

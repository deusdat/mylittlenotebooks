import 'package:mylittlenotebooks/models/notebook.dart';

/// The notebook list (spec FR7, FR8).
///
/// Holds no "currently open notebook" field on purpose: selection is derived
/// from the route, and storing it here would duplicate the source of truth and
/// reintroduce the drift spec FR13 forbids.
class NotebooksState {
  final List<Notebook> notebooks;
  final Notebook Function() create;

  /// Permanently deletes the notebook with [id], cascading its exclusive
  /// publications (delete-notebook spec).
  final void Function(String id) delete;

  const NotebooksState({
    required this.notebooks,
    required this.create,
    required this.delete,
  });

  /// The notebook with this id, or `null` if it is not in the repository.
  Notebook? byId(String id) {
    for (final notebook in notebooks) {
      if (notebook.id == id) return notebook;
    }
    return null;
  }
}
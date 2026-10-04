import 'package:mylittlenotebooks/data/notebook_repository.dart';
import 'package:mylittlenotebooks/models/notebook.dart';
import 'package:mylittlenotebooks/state/notebooks_state.dart';
import 'package:utopia_hooks/utopia_hooks.dart';

/// Builds [NotebooksState], seeded from the preloaded snapshot so the first
/// frame renders a populated list rather than an empty state that is replaced
/// a frame later.
NotebooksState useNotebooksState({
  required NotebookRepository repo,
  required List<Notebook> preloaded,
}) {
  final notebooks = useState(preloaded);

  Notebook create() {
    final notebook = repo.create();
    notebooks.value = repo.list();
    return notebook;
  }

  void delete(String id) {
    repo.delete(id);
    notebooks.value = repo.list();
  }

  return NotebooksState(
    notebooks: notebooks.value,
    create: create,
    delete: delete,
  );
}
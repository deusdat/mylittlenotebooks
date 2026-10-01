import 'package:mylittlenotebooks/models/notebook.dart';

/// The seam where durable storage lands later.
///
/// Synchronous because the only implementation is in-memory and the router's
/// `redirect` guard needs a synchronous answer. A real backend will want async
/// variants plus a preloaded snapshot in `bootstrap.dart`; the hook layer
/// already seeds from a preloaded value, so that swap is additive.
abstract interface class NotebookRepository {
  /// Notebooks in creation order, oldest first (spec FR8).
  List<Notebook> list();

  /// Appends a notebook titled `Notebook N` and returns it (spec FR7).
  Notebook create();

  bool exists(String id);
}

/// Seeded in-memory store.
///
/// Three notebooks are seeded so the shell is demonstrable on first launch
/// (spec D10). Titles are stable so the reset after a relaunch is predictable.
class InMemoryNotebookRepository implements NotebookRepository {
  static const seedTitles = ['Notebook 1', 'Notebook 2', 'Notebook 3'];

  final List<Notebook> _notebooks = [];
  int _ordinal = 0;

  @override
  List<Notebook> list() => List.unmodifiable(_notebooks);

  @override
  Notebook create() {
    final notebook = Notebook(
      id: 'nb-${_ordinal++}',
      title: 'Notebook $_ordinal',
      createdAt: DateTime.now(),
    );
    _notebooks.add(notebook);
    return notebook;
  }

  @override
  bool exists(String id) => _notebooks.any((notebook) => notebook.id == id);
}

/// Builds the repository and returns it alongside its current contents so the
/// first frame can render a populated list without an async gap.
({NotebookRepository repository, List<Notebook> notebooks}) seededRepository() {
  final repository = InMemoryNotebookRepository();
  for (final _ in InMemoryNotebookRepository.seedTitles) {
    repository.create();
  }
  return (repository: repository, notebooks: repository.list());
}
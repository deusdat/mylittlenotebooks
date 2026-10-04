import 'package:flutter/foundation.dart';
import 'package:mylittlenotebooks/data/first_run_seeder.dart';
import 'package:mylittlenotebooks/data/notebook_repository.dart';
import 'package:mylittlenotebooks/data/objectbox/objectbox_store.dart';
import 'package:mylittlenotebooks/data/objectbox_notebook_repository.dart';
import 'package:mylittlenotebooks/data/panel_state_store.dart';
import 'package:mylittlenotebooks/data/prefs_panel_state_store.dart';
import 'package:mylittlenotebooks/models/notebook.dart';

/// Everything the widget tree needs, constructed before `runApp`.
///
/// Dependencies are passed by constructor argument rather than resolved from a
/// service locator (spec NFR3). The two things that genuinely must happen
/// before the first frame are the panel's stored intent, because the panel has
/// to render at the right width immediately (spec AC8, AC9), and the library
/// store, because ObjectBox refuses to open the same directory twice.
///
/// The store itself is **not** exposed here. Bootstrap owns it and hands out
/// repositories; a caller that needs a store builds its own repositories over
/// `openTestStore()` instead. That keeps `lib/` free of ObjectBox types outside
/// the data layer (spec NFR5).
class BootstrapResult {
  final PanelStateStore store;
  final NotebookRepository notebooks;
  final List<Notebook> initialNotebooks;
  final bool panelCollapsed;

  const BootstrapResult({
    required this.store,
    required this.notebooks,
    required this.initialNotebooks,
    required this.panelCollapsed,
  });
}

BootstrapResult? _cached;

/// Reads the stored panel intent, opens the library store, and builds the
/// repositories.
///
/// Awaited in `main()` before `runApp`. Cached so a hot restart cannot rebuild
/// the store or throw on re-registration (spec NFR2).
///
/// Pass `notebooks` to substitute a repository — the shell tests do this, which
/// is why no store is opened when one is supplied.
Future<BootstrapResult> bootstrapDependencies({
  PanelStateStore? store,
  NotebookRepository? notebooks,
}) async {
  final cached = _cached;
  if (cached != null) return cached;

  final resolvedStore = store ?? PrefsPanelStateStore();
  final collapsed = await resolvedStore.readCollapsed();

  final NotebookRepository resolvedNotebooks;
  final List<Notebook> initial;
  if (notebooks != null) {
    resolvedNotebooks = notebooks;
    initial = notebooks.list();
  } else {
    // Opened exactly once, before the first frame.
    final libraryStore = await openLibraryStore();
    final repo = ObjectBoxNotebookRepository(libraryStore);
    // Exactly once per install, recorded in the store itself — not "if empty",
    // which would re-seed after a delete-all (shell spec D10).
    FirstRunSeeder(libraryStore).seedOnce(repo);
    resolvedNotebooks = repo;
    initial = repo.list();
  }

  assert(() {
    debugPrint('[bootstrap] panelCollapsed=$collapsed');
    return true;
  }());

  final result = BootstrapResult(
    store: resolvedStore,
    notebooks: resolvedNotebooks,
    initialNotebooks: initial,
    panelCollapsed: collapsed,
  );
  _cached = result;
  return result;
}

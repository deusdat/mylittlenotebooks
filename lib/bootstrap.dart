import 'package:flutter/foundation.dart';
import 'package:mylittlenotebooks/data/notebook_repository.dart';
import 'package:mylittlenotebooks/data/panel_state_store.dart';
import 'package:mylittlenotebooks/data/prefs_panel_state_store.dart';
import 'package:mylittlenotebooks/models/notebook.dart';

/// Everything the widget tree needs, constructed before `runApp`.
///
/// Dependencies are passed by constructor argument rather than resolved from a
/// service locator (spec NFR3). The one thing that genuinely must happen before
/// the first frame is the panel's stored intent, because the panel has to render
/// at the right width immediately (spec AC8, AC9).
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

/// Reads the stored panel intent and builds the repositories.
///
/// Awaited in `main()` before `runApp`, which is what lets `usePanelState` seed
/// `useState` synchronously and makes a launch-time flash impossible. Cached so
/// a hot restart cannot rebuild the store or throw on re-registration.
Future<BootstrapResult> bootstrapDependencies({
  PanelStateStore? store,
  NotebookRepository? notebooks,
}) async {
  final cached = _cached;
  if (cached != null) return cached;

  final resolvedStore = store ?? PrefsPanelStateStore();
  final seeded = notebooks == null
      ? seededRepository()
      : (repository: notebooks, notebooks: notebooks.list());
  final collapsed = await resolvedStore.readCollapsed();

  assert(() {
    debugPrint('[bootstrap] panelCollapsed=$collapsed');
    return true;
  }());

  final result = BootstrapResult(
    store: resolvedStore,
    notebooks: seeded.repository,
    initialNotebooks: seeded.notebooks,
    panelCollapsed: collapsed,
  );
  _cached = result;
  return result;
}
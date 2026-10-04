import 'package:flutter/foundation.dart';
import 'package:mylittlenotebooks/data/ai_config_repository.dart';
import 'package:mylittlenotebooks/data/first_run_seeder.dart';
import 'package:mylittlenotebooks/data/notebook_repository.dart';
import 'package:mylittlenotebooks/data/objectbox/objectbox_store.dart';
import 'package:mylittlenotebooks/data/objectbox_ai_config_repository.dart';
import 'package:mylittlenotebooks/data/objectbox_notebook_repository.dart';
import 'package:mylittlenotebooks/data/panel_state_store.dart';
import 'package:mylittlenotebooks/data/prefs_panel_state_store.dart';
import 'package:mylittlenotebooks/data/secrets/flutter_secure_token_store.dart';
import 'package:mylittlenotebooks/models/ai_endpoint_config.dart';
import 'package:mylittlenotebooks/models/notebook.dart';

/// Everything the widget tree needs, constructed before `runApp`.
///
/// Dependencies are passed by constructor argument rather than resolved from a
/// service locator (spec NFR3). The things that genuinely must happen before the
/// first frame are the panel's stored intent, the library store (ObjectBox
/// refuses to open the same directory twice), and — since settings-for-ai — each
/// AI tuple's `hasToken` flag, because the list must render it synchronously and
/// the secret store is async (Directive 6, plan I6).
class BootstrapResult {
  final PanelStateStore store;
  final NotebookRepository notebooks;
  final List<Notebook> initialNotebooks;
  final AiConfigRepository aiConfigs;
  final List<AiEndpointConfig> initialAiConfigs;
  final bool panelCollapsed;

  const BootstrapResult({
    required this.store,
    required this.notebooks,
    required this.initialNotebooks,
    required this.aiConfigs,
    required this.initialAiConfigs,
    required this.panelCollapsed,
  });
}

BootstrapResult? _cached;

/// Reads the stored panel intent, opens the library store, warms the AI token
/// flags, and builds the repositories.
///
/// Awaited in `main()` before `runApp`. Cached so a hot restart cannot rebuild
/// the store or throw on re-registration (spec NFR2).
///
/// Pass [notebooks]/[aiConfigs] to substitute repositories — the shell tests do
/// this, which is why no store is opened when they are supplied.
Future<BootstrapResult> bootstrapDependencies({
  PanelStateStore? store,
  NotebookRepository? notebooks,
  AiConfigRepository? aiConfigs,
}) async {
  final cached = _cached;
  if (cached != null) return cached;

  final resolvedStore = store ?? PrefsPanelStateStore();
  final collapsed = await resolvedStore.readCollapsed();

  final NotebookRepository resolvedNotebooks;
  final AiConfigRepository resolvedAiConfigs;
  final List<Notebook> initialNotebooks;
  final List<AiEndpointConfig> initialAiConfigs;

  if (notebooks != null) {
    // Test/shell path: repositories are supplied, no store is opened.
    resolvedNotebooks = notebooks;
    initialNotebooks = notebooks.list();
    resolvedAiConfigs = aiConfigs ?? InMemoryAiConfigRepository();
    initialAiConfigs = resolvedAiConfigs.list();
  } else {
    // Opened exactly once, before the first frame.
    final libraryStore = await openLibraryStore();
    final repo = ObjectBoxNotebookRepository(libraryStore);
    // Exactly once per install, recorded in the store itself — not "if empty",
    // which would re-seed after a delete-all (shell spec D10).
    FirstRunSeeder(libraryStore).seedOnce(repo);
    resolvedNotebooks = repo;
    initialNotebooks = repo.list();

    // Warm `hasToken` (one `exists` per tuple, no secret read) and sweep orphan
    // secrets before the first frame, so the Settings list is correct without an
    // async hook (plan I6, FR18).
    resolvedAiConfigs = ObjectBoxAiConfigRepository(
      libraryStore,
      FlutterSecureTokenStore(),
    );
    await resolvedAiConfigs.refreshTokenFlags();
    await resolvedAiConfigs.reconcile();
    initialAiConfigs = resolvedAiConfigs.list();
  }

  assert(() {
    debugPrint('[bootstrap] panelCollapsed=$collapsed');
    return true;
  }());

  final result = BootstrapResult(
    store: resolvedStore,
    notebooks: resolvedNotebooks,
    initialNotebooks: initialNotebooks,
    aiConfigs: resolvedAiConfigs,
    initialAiConfigs: initialAiConfigs,
    panelCollapsed: collapsed,
  );
  _cached = result;
  return result;
}

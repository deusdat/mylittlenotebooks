import 'package:flutter/material.dart';
import 'package:mylittlenotebooks/data/ai_config_repository.dart';
import 'package:mylittlenotebooks/data/note_environment.dart';
import 'package:mylittlenotebooks/data/notebook_repository.dart';
import 'package:mylittlenotebooks/data/panel_state_store.dart';
import 'package:mylittlenotebooks/models/ai_endpoint_config.dart';
import 'package:mylittlenotebooks/models/notebook.dart';
import 'package:mylittlenotebooks/router/app_router.dart';
import 'package:mylittlenotebooks/state/ai_configs_state.dart';
import 'package:mylittlenotebooks/state/notebooks_state.dart';
import 'package:mylittlenotebooks/state/panel_state.dart';
import 'package:mylittlenotebooks/state/use_ai_configs_state.dart';
import 'package:mylittlenotebooks/state/use_notebooks_state.dart';
import 'package:mylittlenotebooks/state/use_panel_state.dart';
import 'package:utopia_hooks/utopia_hooks.dart';

/// The application root.
///
/// Registers only *reactive* state globally. [PanelStateStore],
/// [NotebookRepository], and [AiConfigRepository] are constructor-injected
/// because registering constants as providers would add indirection without
/// benefit — and would obscure that the app has no service locator at all
/// (spec NFR3).
class App extends HookWidget {
  final bool preloadedCollapsed;
  final PanelStateStore store;
  final NotebookRepository repo;
  final List<Notebook> initialNotebooks;
  final AiConfigRepository aiConfigs;
  final List<AiEndpointConfig> initialAiConfigs;
  final NoteEnvironment noteEnv;

  const App({
    super.key,
    required this.preloadedCollapsed,
    required this.store,
    required this.repo,
    required this.initialNotebooks,
    required this.aiConfigs,
    required this.initialAiConfigs,
    required this.noteEnv,
  });

  @override
  Widget build(BuildContext context) {
    // Memoized because a GoRouter allocates a navigator and owns navigation
    // state — unlike the panel's pure geometry, this genuinely must not be
    // rebuilt. `App` rebuilds would otherwise reset the navigation stack.
    final router = useMemoized(
      () => appRouter(repo, noteEnv),
      [repo, noteEnv],
      (router) => router.dispose(),
    );

    // The providers map is positional: the constructor takes it as its first
    // argument. The package README shows a named `providers:` parameter, which
    // does not compile against 0.4.26+1.
    return HookProviderContainerWidget(
      {
        PanelState: () =>
            usePanelState(preloaded: preloadedCollapsed, store: store),
        NotebooksState: () =>
            useNotebooksState(repo: repo, preloaded: initialNotebooks),
        AiConfigsState: () => useAiConfigsState(
              repo: aiConfigs,
              preloaded: initialAiConfigs,
            ),
      },
      child: MaterialApp.router(
        title: 'My Little Notebooks',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        ),
        themeMode: ThemeMode.system,
        routerConfig: router,
      ),
    );
  }
}
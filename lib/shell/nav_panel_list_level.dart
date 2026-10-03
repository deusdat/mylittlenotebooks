import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mylittlenotebooks/shell/nav_destination_tile.dart';
import 'package:mylittlenotebooks/shell/nav_panel_body.dart';
import 'package:mylittlenotebooks/state/notebooks_state.dart';
import 'package:utopia_hooks/utopia_hooks.dart';

/// The list-level panel content: Add Notebook, the notebook list, and Settings.
class NavPanelListLevel extends HookWidget {
  final bool collapsed;

  const NavPanelListLevel({super.key, required this.collapsed});

  @override
  Widget build(BuildContext context) {
    final notebooks = useProvided<NotebooksState>();
    final router = GoRouter.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NavDestinationTile(
          icon: Icons.add,
          label: 'Add Notebook',
          collapsed: collapsed,
          order: 1.0,
          // Create and open in one action (spec AC10): the new notebook is
          // appended at the end of the list and immediately navigated to.
          onTap: () {
            final notebook = notebooks.create();
            _openNotebook(router, notebook.id);
          },
        ),
        Expanded(
          child: notebooks.notebooks.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'No notebooks yet. Use Add Notebook to create one.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                )
              : ListView.builder(
                  // Restores the scroll offset when returning from a notebook
                  // (spec AC13). The per-notebook CustomTransitionPage keys do
                  // the rest.
                  key: const PageStorageKey<String>('notebook-list'),
                  padding: EdgeInsets.zero,
                  itemCount: notebooks.notebooks.length,
                  itemBuilder: (context, index) {
                    final notebook = notebooks.notebooks[index];
                    return NavDestinationTile(
                      icon: Icons.menu_book_outlined,
                      label: notebook.title,
                      collapsed: collapsed,
                      order: 2.0 + index,
                      onTap: () => _openNotebook(router, notebook.id),
                    );
                  },
                ),
        ),
        NavSettingsTile(collapsed: collapsed),
      ],
    );
  }
}

/// Pushes the route for [notebookId], unless it is already on the stack.
///
/// **A `push` appends, and every notebook page carries a stable per-notebook key**
/// (`ValueKey('notebook-$notebookId')` — spec AC13, so each notebook keeps its own
/// route state and back restores scroll position). Those two facts together mean a
/// repeated push of the same notebook puts **two pages with the same key** into
/// one `Navigator`, which Flutter rejects outright:
///
/// ```
/// Failed assertion: line 4096 pos 18: '!keyReservation.contains(key)': is not true.
/// ```
///
/// One stray double-click reaches it. The nav panel is a `ListView` of tiles whose
/// `onTap` is `push`, and both taps of a double-click are delivered before the
/// next frame is built — so the panel has not yet rebuilt into the detail level
/// that would otherwise hide the tile and make a second tap impossible.
///
/// The alternative fixes are both worse. `go` replaces the stack, which would
/// break FR9/D3: a real push is what makes platform back affordances work, and
/// there is a whole acceptance criterion (AC13) about back restoring the list.
/// Making the key unique per push would silence the assertion and leave five
/// identical notebook pages stacked from five clicks.
///
/// So the push stays and becomes idempotent. Deliberately **not** a debounce: a
/// debounce would also swallow a deliberate rapid tap on a *different* notebook,
/// which is a real navigation the user asked for.
void _openNotebook(GoRouter router, String notebookId) {
  final location = '/notebook/$notebookId';
  if (router.state.uri.path == location) return;
  router.push(location);
}
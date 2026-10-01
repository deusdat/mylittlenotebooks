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
            router.push('/notebook/${notebook.id}');
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
                      onTap: () => router.push('/notebook/${notebook.id}'),
                    );
                  },
                ),
        ),
        NavSettingsTile(collapsed: collapsed),
      ],
    );
  }
}
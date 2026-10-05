import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mylittlenotebooks/data/note_environment.dart';
import 'package:mylittlenotebooks/models/notebook_section.dart';
import 'package:mylittlenotebooks/shell/nav_destination_tile.dart';
import 'package:mylittlenotebooks/shell/nav_panel_body.dart';
import 'package:mylittlenotebooks/state/notebooks_state.dart';
import 'package:mylittlenotebooks/state/use_notes_list.dart';
import 'package:utopia_hooks/utopia_hooks.dart';

/// The detail-level panel content: which notebook you are in, its own detail
/// navigation, and — under the Notes section — the notebook's notes (FR26).
class NavPanelDetailLevel extends HookWidget {
  final bool collapsed;
  final String notebookId;
  final NoteEnvironment noteEnv;

  const NavPanelDetailLevel({
    super.key,
    required this.collapsed,
    required this.notebookId,
    required this.noteEnv,
  });

  @override
  Widget build(BuildContext context) {
    final notebooks = useProvided<NotebooksState>();
    final theme = Theme.of(context);
    final notebook = notebooks.byId(notebookId);

    // Hooked unconditionally (hook rules); only rendered when Notes is selected.
    final notesList =
        useNotesList(notebookId: notebookId, repo: noteEnv.notes);

    // Selection is derived from the route, never stored (spec FR13). Match on
    // **path segments**, not a substring: `/notebook/<id>` contains the text
    // `/note`, so a `contains('/note')` test highlights Notes on every notebook
    // page.
    final segments = GoRouterState.of(context).uri.pathSegments;
    final notesSelected = segments.length >= 3 &&
        (segments[2] == 'notes' || segments[2] == 'note');
    final currentNoteId = (segments.length >= 4 && segments[2] == 'note')
        ? segments[3]
        : null;

    String routeFor(String sectionId) => switch (sectionId) {
          'notes' => '/notebook/$notebookId/notes',
          _ => '/notebook/$notebookId',
        };

    final children = <Widget>[
      NavDestinationTile(
        icon: Icons.arrow_back,
        label: 'Back to notebooks',
        collapsed: collapsed,
        order: 1.0,
        onTap: () {
          // Pop when there is a page beneath; otherwise fall back to the list so
          // this control always does something (the stack can be reset by a
          // section switch, which uses `go`).
          final router = GoRouter.of(context);
          if (router.canPop()) {
            router.pop();
          } else {
            router.go('/');
          }
        },
      ),
      Divider(height: 1, color: theme.colorScheme.outlineVariant),
      Padding(
        padding: EdgeInsets.symmetric(horizontal: collapsed ? 0 : 12, vertical: 8),
        child: Text(
          notebook?.title ?? 'Notebook',
          textAlign: collapsed ? TextAlign.center : TextAlign.start,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: theme.colorScheme.onSurface,
          ),
        ),
      ),
      Divider(height: 1, color: theme.colorScheme.outlineVariant),
    ];

    for (var index = 0; index < notebookSections.length; index++) {
      final section = notebookSections[index];
      final selected = section.id == 'notes'
          ? notesSelected
          : section.id == 'overview' && !notesSelected;

      children.add(NavDestinationTile(
        icon: section.icon,
        label: section.label,
        collapsed: collapsed,
        enabled: section.enabled,
        selected: section.enabled && selected,
        unavailableTooltip: '${section.label} is not yet available',
        order: 2.0 + index,
        onTap: section.enabled ? () => context.go(routeFor(section.id)) : () {},
      ));

      // The Notes section expands to its list plus Add note (spec FR26).
      if (section.id == 'notes' && notesSelected && !collapsed) {
        for (final note in notesList.notes) {
          children.add(NavDestinationTile(
            icon: Icons.sticky_note_2_outlined,
            label: (note.title == null || note.title!.trim().isEmpty)
                ? 'Untitled note'
                : note.title!,
            collapsed: false,
            selected: currentNoteId == note.uuid,
            order: 2.0 + index + 0.5,
            // `push`, not `go`: the note must stack over the notes section so
            // Back returns to it, rather than replacing the stack (which is what
            // broke Back).
            onTap: () =>
                context.push('/notebook/$notebookId/note/${note.uuid}'),
          ));
        }
        children.add(NavDestinationTile(
          icon: Icons.add,
          label: 'Add note',
          collapsed: false,
          order: 2.0 + index + 0.9,
          onTap: () => context.push('/notebook/$notebookId/note/new'),
        ));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            key: PageStorageKey<String>('notebook-sections-$notebookId'),
            padding: EdgeInsets.zero,
            children: children,
          ),
        ),
        NavSettingsTile(collapsed: collapsed),
      ],
    );
  }
}

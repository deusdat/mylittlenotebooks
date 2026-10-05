import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mylittlenotebooks/data/note_environment.dart';
import 'package:mylittlenotebooks/models/nav_level.dart';
import 'package:mylittlenotebooks/shell/nav_destination_tile.dart';
import 'package:mylittlenotebooks/shell/nav_panel_detail_level.dart';
import 'package:mylittlenotebooks/shell/nav_panel_list_level.dart';

/// Dispatches between the two panel levels.
///
/// A [StatelessWidget] switching exhaustively over the sealed [NavLevel], so
/// adding a level is a compile error rather than a silently blank panel. The
/// level arrives as an already-derived value, so there are no hooks here.
class NavPanelBody extends StatelessWidget {
  final bool collapsed;
  final NavLevel navLevel;
  final NoteEnvironment noteEnv;

  const NavPanelBody({
    super.key,
    required this.collapsed,
    required this.navLevel,
    required this.noteEnv,
  });

  @override
  Widget build(BuildContext context) => switch (navLevel) {
    NavLevelList() => NavPanelListLevel(collapsed: collapsed),
    NavLevelDetail(:final notebookId) => NavPanelDetailLevel(
        collapsed: collapsed,
        notebookId: notebookId,
        noteEnv: noteEnv,
      ),
  };
}

/// The Settings destination, pinned to the bottom of the panel in both forms
/// (spec FR12).
class NavSettingsTile extends StatelessWidget {
  final bool collapsed;

  const NavSettingsTile({super.key, required this.collapsed});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Divider(
          height: 1,
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
        NavDestinationTile(
          icon: Icons.settings_outlined,
          label: 'Settings',
          collapsed: collapsed,
          order: 1.0,
          onTap: () => context.push('/settings'),
        ),
      ],
    );
  }
}
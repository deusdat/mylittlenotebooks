import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mylittlenotebooks/models/notebook_section.dart';
import 'package:mylittlenotebooks/shell/nav_destination_tile.dart';
import 'package:mylittlenotebooks/shell/nav_panel_body.dart';
import 'package:mylittlenotebooks/state/notebooks_state.dart';
import 'package:utopia_hooks/utopia_hooks.dart';

/// The detail-level panel content: which notebook you are in, its own detail
/// navigation, and a back control.
///
/// Deliberately renders neither the notebook list nor the Add Notebook button
/// (spec FR10, AC12). Their absence is asserted in `nav_state_machine_test.dart`
/// rather than left to inspection.
class NavPanelDetailLevel extends HookWidget {
  final bool collapsed;
  final String notebookId;

  const NavPanelDetailLevel({
    super.key,
    required this.collapsed,
    required this.notebookId,
  });

  @override
  Widget build(BuildContext context) {
    final notebooks = useProvided<NotebooksState>();
    final theme = Theme.of(context);
    final notebook = notebooks.byId(notebookId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NavDestinationTile(
          icon: Icons.arrow_back,
          label: 'Back to notebooks',
          collapsed: collapsed,
          order: 1.0,
          onTap: () {
            if (context.canPop()) context.pop();
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
        Expanded(
          child: ListView(
            key: PageStorageKey<String>('notebook-sections-$notebookId'),
            padding: EdgeInsets.zero,
            children: [
              for (var index = 0; index < notebookSections.length; index++)
                NavDestinationTile(
                  icon: notebookSections[index].icon,
                  label: notebookSections[index].label,
                  collapsed: collapsed,
                  enabled: notebookSections[index].enabled,
                  selected: notebookSections[index].enabled,
                  unavailableTooltip:
                      '${notebookSections[index].label} is not yet available',
                  order: 2.0 + index,
                  onTap: () {},
                ),
            ],
          ),
        ),
        NavSettingsTile(collapsed: collapsed),
      ],
    );
  }
}
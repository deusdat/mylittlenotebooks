import 'package:flutter/material.dart';
import 'package:mylittlenotebooks/models/nav_level.dart';
import 'package:mylittlenotebooks/shell/nav_destination_tile.dart';
import 'package:mylittlenotebooks/shell/nav_panel_body.dart';

/// The navigation panel.
///
/// A [StatelessWidget] receiving an already-resolved width: it must not
/// re-derive geometry and must never read or store a window width, so there is
/// exactly one source for the panel's size (spec FR3).
class NavPanel extends StatelessWidget {
  final double width;
  final bool collapsed;
  final NavLevel navLevel;
  final VoidCallback onToggleCollapsed;

  const NavPanel({
    super.key,
    required this.width,
    required this.collapsed,
    required this.navLevel,
    required this.onToggleCollapsed,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.decelerate,
      width: width,
      clipBehavior: Clip.hardEdge,
      color: theme.colorScheme.surfaceContainerLow,
      foregroundDecoration: BoxDecoration(
        border: Border(
          right: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: _PanelColumn(
        collapsed: collapsed,
        navLevel: navLevel,
        onToggleCollapsed: onToggleCollapsed,
      ),
    );
  }
}

class _PanelColumn extends StatelessWidget {
  final bool collapsed;
  final NavLevel navLevel;
  final VoidCallback onToggleCollapsed;

  const _PanelColumn({
    required this.collapsed,
    required this.navLevel,
    required this.onToggleCollapsed,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Deterministic keyboard order within the panel (spec AC19).
    return FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NavDestinationTile(
            icon: collapsed ? Icons.chevron_right : Icons.chevron_left,
            label: collapsed ? 'Expand panel' : 'Collapse panel',
            collapsed: collapsed,
            order: 1.0,
            onTap: onToggleCollapsed,
          ),
          Divider(height: 1, color: theme.colorScheme.outlineVariant),
          Expanded(
            child: NavPanelBody(collapsed: collapsed, navLevel: navLevel),
          ),
        ],
      ),
    );
  }
}
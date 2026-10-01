import 'package:flutter/material.dart';

/// One navigation destination.
///
/// The same widget serves the expanded panel and the icon rail, so a
/// destination cannot become reachable in one form and unreachable in the other
/// (spec AC5, AC6).
class NavDestinationTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// Whether the panel is in rail form. Drives label visibility only — never
  /// measured from available width.
  final bool collapsed;

  final bool selected;
  final bool enabled;

  /// Tooltip shown when the destination exists but is not implemented yet.
  final String? unavailableTooltip;

  /// Keyboard traversal order within the panel (spec AC19). Lower is earlier.
  final double order;

  const NavDestinationTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    required this.collapsed,
    this.selected = false,
    this.enabled = true,
    this.unavailableTooltip,
    this.order = 0,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = !enabled
        ? theme.disabledColor
        : selected
        ? theme.colorScheme.onSecondaryContainer
        : theme.colorScheme.onSurfaceVariant;

    final tile = InkWell(
      onTap: enabled ? onTap : null,
      child: Container(
        color: selected ? theme.colorScheme.secondaryContainer : null,
        alignment: collapsed
            ? Alignment.center
            : AlignmentDirectional.centerStart,
        padding: EdgeInsets.symmetric(
          horizontal: collapsed ? 0 : 12,
          vertical: 12,
        ),
        child: collapsed
            ? Icon(icon, size: 22, color: foreground)
            : Row(
                children: [
                  Icon(icon, size: 20, color: foreground),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: foreground,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );

    final labelled = collapsed ? _iconOnly(tile, theme) : _iconAndLabel(tile);

    // Deterministic keyboard order within the panel. Applied with
    // FocusTraversalOrder + OrderedTraversalPolicy rather than
    // Semantics.sortKey, because NumericFocusOrder is a FocusOrder, not a
    // SemanticsSortKey.
    return FocusTraversalOrder(
      order: NumericFocusOrder(order),
      child: labelled,
    );
  }

  Widget _iconAndLabel(Widget tile) => Semantics(
    button: true,
    enabled: enabled,
    selected: selected,
    child: tile,
  );

  // Icon-only form carries both a tooltip and a semantic label: a Tooltip alone
  // does not reliably expose an accessible name across platforms, which is why
  // the spec requires both (spec AC6, NFR6).
  Widget _iconOnly(Widget tile, ThemeData theme) {
    final accessibleLabel = enabled ? label : '$label (not yet available)';
    return Tooltip(
      message: enabled ? label : unavailableTooltip ?? accessibleLabel,
      child: Semantics(
        button: true,
        enabled: enabled,
        selected: selected,
        excludeSemantics: true,
        label: accessibleLabel,
        child: tile,
      ),
    );
  }
}
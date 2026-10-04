/// The panel's user intent — the one persisted value (spec FR2, FR5) — plus the
/// transient narrow-window overlay (spec rev 5, FR15).
///
/// Deliberately holds no width and no presentation. Both are derived from the
/// live window width by `PanelGeometry`, which is what lets the geometry be
/// tested with no window and what keeps the stored surface down to a boolean.
///
/// [overlayOpen] is **not** persisted. It models the panel being opened over the
/// centre page on a sub-breakpoint window, and is cleared on the first
/// navigation. It never affects the docked panel.
///
/// Imports neither hooks nor Flutter so it stays constructible in a plain test.
class PanelState {
  /// Whether the user asked for the panel to be collapsed. Never changed by the
  /// app acting on its own.
  final bool collapsedByUser;

  /// Whether the narrow-window overlay is currently open (spec FR15). Transient;
  /// never persisted.
  final bool overlayOpen;

  /// Flips [collapsedByUser] and persists it. Used on a dockable window.
  final void Function() toggleCollapsed;

  /// Opens the narrow-window overlay (spec FR15).
  final void Function() openOverlay;

  /// Closes the narrow-window overlay without touching intent.
  final void Function() closeOverlay;

  const PanelState({
    required this.collapsedByUser,
    required this.overlayOpen,
    required this.toggleCollapsed,
    required this.openOverlay,
    required this.closeOverlay,
  });
}
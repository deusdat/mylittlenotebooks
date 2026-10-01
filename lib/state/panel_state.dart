/// The panel's user intent — the one persisted value (spec FR2, FR5).
///
/// Deliberately holds no width and no presentation. Both are derived from the
/// live window width by `PanelGeometry`, which is what lets the geometry be
/// tested with no window and what keeps the stored surface down to a boolean.
///
/// Imports neither hooks nor Flutter so it stays constructible in a plain test.
class PanelState {
  /// Whether the user asked for the panel to be collapsed. Never changed by the
  /// app acting on its own.
  final bool collapsedByUser;

  final void Function() toggleCollapsed;

  const PanelState({
    required this.collapsedByUser,
    required this.toggleCollapsed,
  });
}
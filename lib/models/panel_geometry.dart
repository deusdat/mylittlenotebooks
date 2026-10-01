import 'dart:math' as math;

/// Single source of truth for panel geometry.
///
/// Pure Dart on purpose: no `dart:ui`, no `package:flutter`, so the whole
/// panel model is testable with a plain `test()` and no widget binding.
///
/// Panel width is never stored. It is a function of the live window width and
/// the user's collapsed preference, so shrinking the window needs no listener
/// and no write-back (spec FR3, FR6).
abstract final class PanelGeometry {
  /// The panel's share of the window while expanded (spec FR3).
  static const double maxWidthFraction = 0.20;

  /// Narrowest legible panel.
  static const double minExpandedWidth = 180.0;

  /// Widest useful panel. Engages the clamp at 1600 px.
  static const double maxExpandedWidth = 320.0;

  /// Standard Material icon-rail width (spec FR4).
  static const double railWidth = 56.0;

  /// The window width below which an expanded panel can no longer honour both
  /// [minExpandedWidth] and [maxWidthFraction].
  ///
  /// Derived rather than chosen, so [minExpandedWidth] and
  /// [maxWidthFraction] can never drift apart (spec FR6).
  static double get dockBreakpoint => minExpandedWidth / maxWidthFraction;

  /// Whether the window is wide enough to show an expanded panel.
  ///
  /// A `NaN` or negative width compares false here, so degenerate input falls
  /// through to the rail rather than producing nonsense.
  static bool isDockable(double windowWidth) => windowWidth >= dockBreakpoint;

  /// Effective collapsed state: the user's preference OR a too-narrow window.
  ///
  /// This is a single boolean expression rather than a mode enum or a
  /// presentation table, because a single rule cannot contradict itself — which
  /// is what removed the revision-1 conflict between the 20% ceiling and the
  /// 180 px floor.
  static bool isCollapsed({
    required double windowWidth,
    required bool collapsedByUser,
  }) =>
      collapsedByUser || !isDockable(windowWidth);

  /// Expanded panel width: exactly 20% between 900 and 1600 px, 180 px at 900,
  /// then fixed at 320 px.
  ///
  /// The `minExpandedWidth` floor is unreachable for any dockable width (that
  /// is what [dockBreakpoint] means) and is retained as a defensive assertion
  /// of that invariant. `panel_geometry_test.dart` checks the invariant
  /// directly rather than trusting it.
  static double expandedWidthFor(double windowWidth) {
    if (!windowWidth.isFinite || windowWidth <= 0) return railWidth;
    return math.min(
      maxExpandedWidth,
      math.max(minExpandedWidth, windowWidth * maxWidthFraction),
    );
  }

  /// The rail never exceeds the window, so the centre page always receives a
  /// positive share (spec AC6, AC7).
  static double railWidthFor(double windowWidth) {
    if (!windowWidth.isFinite || windowWidth <= 0) return 0;
    return math.min(railWidth, windowWidth);
  }

  /// Resolved panel width for a window and preference.
  static double widthFor({
    required double windowWidth,
    required bool collapsedByUser,
  }) {
    if (!windowWidth.isFinite) return railWidthFor(0);
    return isCollapsed(
          windowWidth: windowWidth,
          collapsedByUser: collapsedByUser,
        )
        ? railWidthFor(windowWidth)
        : expandedWidthFor(windowWidth);
  }
}
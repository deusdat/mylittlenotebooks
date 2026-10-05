import 'dart:math' as math;

/// Single source of truth for the right-hand chat panel's width (spec FR31).
///
/// Pure Dart on purpose: no `dart:ui`, no `package:flutter`, so the whole model
/// is testable with a plain `test()`. Width is never stored; it is a function of
/// the live window width and the user's collapsed preference, mirroring
/// [PanelGeometry].
///
/// **Window width does not collapse the panel** — only the user's preference
/// does. A narrow window *narrows* the expanded panel (capped so the note body
/// keeps [minContentWidth]) instead of forcing a rail. The chat panel is always
/// docked within the note editor; it has no overlay form.
abstract final class ChatPanelGeometry {
  /// The panel's share of the window while expanded.
  static const double maxWidthFraction = 0.24;

  /// Narrowest legible chat panel.
  static const double minExpandedWidth = 220.0;

  /// Widest useful chat panel.
  static const double maxExpandedWidth = 420.0;

  /// The collapsed rail width.
  static const double railWidth = 48.0;

  /// The least width the expanded panel leaves for the note body.
  static const double minContentWidth = 280.0;

  /// Effective collapsed state: **the user's preference alone**.
  static bool isCollapsed({required bool collapsedByUser}) => collapsedByUser;

  /// Expanded width: 24% between the preferred bounds, capped so the note body
  /// keeps at least [minContentWidth].
  static double expandedWidthFor(double windowWidth) {
    if (!windowWidth.isFinite || windowWidth <= 0) return railWidth;
    final preferred = math.min(
      maxExpandedWidth,
      math.max(minExpandedWidth, windowWidth * maxWidthFraction),
    );
    final cap = windowWidth - minContentWidth;
    if (cap <= railWidth) return railWidth;
    return math.min(preferred, cap);
  }

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
    return collapsedByUser
        ? railWidthFor(windowWidth)
        : expandedWidthFor(windowWidth);
  }
}

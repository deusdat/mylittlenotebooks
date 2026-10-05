import 'dart:math' as math;

/// Single source of truth for the navigation panel's docked width.
///
/// Pure Dart on purpose: no `dart:ui`, no `package:flutter`, so the whole model
/// is testable with a plain `test()` and no widget binding.
///
/// **Form factor, not window width, decides dock-vs-overlay.** The shell docks
/// the panel on desktop and uses a transient overlay on mobile (see
/// `isDesktopPlatform`). This class only resolves *how wide* the docked panel
/// is, so a narrow desktop window **shrinks** the panel rather than collapsing
/// it: the user's collapsed preference is the only thing that makes it a rail.
abstract final class PanelGeometry {
  /// The panel's share of the window while expanded (spec FR3).
  static const double maxWidthFraction = 0.20;

  /// Narrowest legible docked panel.
  static const double minExpandedWidth = 180.0;

  /// Widest useful panel.
  static const double maxExpandedWidth = 320.0;

  /// Standard Material icon-rail width.
  static const double railWidth = 56.0;

  /// The least content width the expanded panel leaves; it caps the panel so the
  /// centre page stays usable on a narrow desktop window.
  static const double minContentWidth = 240.0;

  /// Effective collapsed state: **the user's preference alone**.
  ///
  /// Window width no longer forces a rail — on desktop a narrow window narrows
  /// the panel instead (see [expandedWidthFor]). Overlay, not rail, is the
  /// narrow-mobile behaviour, and that decision lives in the shell.
  static bool isCollapsed({required bool collapsedByUser}) => collapsedByUser;

  /// Docked expanded width: 20% between ~900 and 1600 px, clamped to
  /// [minExpandedWidth]..[maxExpandedWidth], and capped so at least
  /// [minContentWidth] is left for the centre page.
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

  /// The rail never exceeds the window, so the centre page always receives a
  /// positive share (spec AC6, AC7).
  static double railWidthFor(double windowWidth) {
    if (!windowWidth.isFinite || windowWidth <= 0) return 0;
    return math.min(railWidth, windowWidth);
  }

  /// Resolved docked width for a window and preference.
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

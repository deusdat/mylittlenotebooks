import 'package:mylittlenotebooks/models/panel_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pure geometry tests. No widget binding, no `HookContext`, no Flutter
/// imports anywhere in this file — if one is ever needed, a framework
/// dependency has leaked into the panel model (spec NFR5).
void main() {
  group('constants', () {
    test('the docking breakpoint is derived, not chosen', () {
      expect(PanelGeometry.dockBreakpoint, 900.0);
      expect(
        PanelGeometry.dockBreakpoint,
        PanelGeometry.minExpandedWidth / PanelGeometry.maxWidthFraction,
      );
    });
  });

  group('expandedWidthFor', () {
    test('is exactly 20% between 900 and 1600', () {
      for (final width in [900.0, 1000.0, 1200.0, 1400.0, 1599.0, 1600.0]) {
        expect(
          PanelGeometry.expandedWidthFor(width),
          moreOrLessEquals(width * 0.20, epsilon: 0.001),
          reason: 'at $width px the panel should hold the 20% proportion',
        );
      }
    });

    test('is the minimum at the breakpoint', () {
      expect(PanelGeometry.expandedWidthFor(900), 180.0);
    });

    test('is continuous either side of the breakpoint', () {
      expect(PanelGeometry.expandedWidthFor(900), 180.0);
      expect(PanelGeometry.expandedWidthFor(901), moreOrLessEquals(180.2));
    });

    test('clamps at the maximum and stops growing', () {
      expect(PanelGeometry.expandedWidthFor(1600), 320.0);
      expect(PanelGeometry.expandedWidthFor(2000), 320.0);
      expect(PanelGeometry.expandedWidthFor(4000), 320.0);
    });

    test('never violates the 20% proportion for any dockable width', () {
      for (var width = 900.0; width <= 3000; width += 7) {
        final resolved = PanelGeometry.expandedWidthFor(width);
        expect(
          resolved,
          lessThanOrEqualTo(width * PanelGeometry.maxWidthFraction + 0.0001),
          reason: 'panel must not exceed 20% of the window at $width px',
        );
      }
    });

    test('degrades sanely for degenerate widths', () {
      expect(PanelGeometry.expandedWidthFor(double.nan), PanelGeometry.railWidth);
      expect(
        PanelGeometry.expandedWidthFor(double.infinity),
        PanelGeometry.railWidth,
      );
      expect(PanelGeometry.expandedWidthFor(-10), PanelGeometry.railWidth);
      expect(PanelGeometry.expandedWidthFor(0), PanelGeometry.railWidth);
    });

    test('is pure', () {
      expect(
        PanelGeometry.expandedWidthFor(1234),
        PanelGeometry.expandedWidthFor(1234),
      );
    });
  });

  group('isCollapsed', () {
    test('below the breakpoint the panel is a rail regardless of intent', () {
      expect(
        PanelGeometry.isCollapsed(windowWidth: 700, collapsedByUser: false),
        isTrue,
      );
      expect(
        PanelGeometry.isCollapsed(windowWidth: 899, collapsedByUser: false),
        isTrue,
      );
    });

    test('at or above the breakpoint, intent decides', () {
      expect(
        PanelGeometry.isCollapsed(windowWidth: 900, collapsedByUser: false),
        isFalse,
      );
      expect(
        PanelGeometry.isCollapsed(windowWidth: 1600, collapsedByUser: true),
        isTrue,
      );
    });

    test('a narrow window always collapses, even when the user said expanded', () {
      for (var width = 0.0; width < 900; width += 13) {
        expect(
          PanelGeometry.isCollapsed(windowWidth: width, collapsedByUser: false),
          isTrue,
        );
      }
    });
  });

  group('railWidthFor', () {
    test('is 56 px on a normal window', () {
      expect(PanelGeometry.railWidthFor(900), 56.0);
    });

    test('never exceeds the window', () {
      expect(PanelGeometry.railWidthFor(20), 20.0);
      expect(PanelGeometry.railWidthFor(0), 0.0);
      expect(PanelGeometry.railWidthFor(double.nan), 0.0);
    });
  });

  group('widthFor', () {
    test('returns the derived width when expanded and dockable', () {
      expect(
        PanelGeometry.widthFor(windowWidth: 1200, collapsedByUser: false),
        240.0,
      );
    });

    test('returns the rail when the user collapsed it', () {
      expect(
        PanelGeometry.widthFor(windowWidth: 1200, collapsedByUser: true),
        56.0,
      );
    });

    test('returns the rail on a narrow window', () {
      expect(
        PanelGeometry.widthFor(windowWidth: 500, collapsedByUser: false),
        56.0,
      );
    });

    test('the centre page always keeps a positive share', () {
      for (final width in [320.0, 480.0, 700.0, 900.0, 1200.0, 2560.0]) {
        for (final collapsed in [true, false]) {
          final panelWidth = PanelGeometry.widthFor(
            windowWidth: width,
            collapsedByUser: collapsed,
          );
          expect(
            width - panelWidth,
            greaterThan(0),
            reason: 'centre page must stay usable at $width px '
                '(collapsed: $collapsed)',
          );
        }
      }
    });

    test('degrades to zero width for a non-finite window', () {
      expect(
        PanelGeometry.widthFor(
          windowWidth: double.nan,
          collapsedByUser: false,
        ),
        0.0,
      );
    });
  });
}
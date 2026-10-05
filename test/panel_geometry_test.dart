import 'package:mylittlenotebooks/models/panel_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pure geometry tests. No widget binding, no `HookContext`, no Flutter imports
/// anywhere in this file — if one is ever needed, a framework dependency has
/// leaked into the panel model.
///
/// **Form factor is not modelled here.** The shell decides dock-vs-overlay from
/// the platform; this class only resolves the docked width. Window width shrinks
/// the panel rather than collapsing it, so only the user's preference makes a
/// rail.
void main() {
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

    test('is the minimum at 900', () {
      expect(PanelGeometry.expandedWidthFor(900), 180.0);
    });

    test('clamps at the maximum and stops growing', () {
      expect(PanelGeometry.expandedWidthFor(1600), 320.0);
      expect(PanelGeometry.expandedWidthFor(2000), 320.0);
      expect(PanelGeometry.expandedWidthFor(4000), 320.0);
    });

    test('never violates the 20% proportion at or above 900', () {
      for (var width = 900.0; width <= 3000; width += 7) {
        final resolved = PanelGeometry.expandedWidthFor(width);
        expect(
          resolved,
          lessThanOrEqualTo(width * PanelGeometry.maxWidthFraction + 0.0001),
          reason: 'panel must not exceed 20% of the window at $width px',
        );
      }
    });

    test('leaves at least minContentWidth for the centre page', () {
      for (final width in [320.0, 400.0, 480.0, 700.0, 900.0, 1600.0]) {
        final panel = PanelGeometry.expandedWidthFor(width);
        expect(
          width - panel,
          greaterThanOrEqualTo(PanelGeometry.minContentWidth - 0.001),
          reason: 'at $width px the centre page must stay usable',
        );
        expect(panel, greaterThanOrEqualTo(PanelGeometry.railWidth));
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
    test('is the user preference alone; window width does not force a rail', () {
      expect(PanelGeometry.isCollapsed(collapsedByUser: false), isFalse);
      expect(PanelGeometry.isCollapsed(collapsedByUser: true), isTrue);
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
    test('returns the expanded width when expanded', () {
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

    test('narrows, rather than collapsing, on a small window', () {
      expect(
        PanelGeometry.widthFor(windowWidth: 500, collapsedByUser: false),
        180.0,
      );
    });

    test('the expanded panel always leaves minContentWidth', () {
      for (final width in [320.0, 480.0, 700.0, 900.0, 1200.0, 2560.0]) {
        final panelWidth = PanelGeometry.widthFor(
          windowWidth: width,
          collapsedByUser: false,
        );
        expect(
          width - panelWidth,
          greaterThanOrEqualTo(PanelGeometry.minContentWidth - 0.001),
          reason: 'centre page must stay usable at $width px',
        );
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

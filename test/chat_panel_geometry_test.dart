import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/models/chat_panel_geometry.dart';

/// The right-hand chat panel's width (spec FR31), tested with a plain `test()`
/// and no widget binding.
///
/// Window width never collapses the panel — only the user's preference does;
/// a narrow window narrows the expanded panel instead.
void main() {
  group('ChatPanelGeometry', () {
    test('expanded width is clamped between the floor and the ceiling', () {
      expect(ChatPanelGeometry.expandedWidthFor(900),
          ChatPanelGeometry.minExpandedWidth);
      expect(ChatPanelGeometry.expandedWidthFor(100000),
          ChatPanelGeometry.maxExpandedWidth);
    });

    test('leaves at least minContentWidth for the note body', () {
      for (final width in [600.0, 800.0, 1000.0, 1600.0]) {
        final panel = ChatPanelGeometry.expandedWidthFor(width);
        expect(
          width - panel,
          greaterThanOrEqualTo(ChatPanelGeometry.minContentWidth - 0.001),
          reason: 'the note body must stay usable at $width px',
        );
      }
    });

    test('isCollapsed is the user preference alone', () {
      expect(ChatPanelGeometry.isCollapsed(collapsedByUser: false), isFalse);
      expect(ChatPanelGeometry.isCollapsed(collapsedByUser: true), isTrue);
    });

    test('narrows, rather than collapsing, on a small window', () {
      expect(
        ChatPanelGeometry.widthFor(windowWidth: 800, collapsedByUser: false),
        ChatPanelGeometry.minExpandedWidth,
      );
    });

    test('a collapsed panel is the rail width', () {
      expect(
        ChatPanelGeometry.widthFor(windowWidth: 1600, collapsedByUser: true),
        ChatPanelGeometry.railWidth,
      );
    });

    test('widthFor resolves degenerate input to the rail, never nonsense', () {
      expect(
        ChatPanelGeometry.widthFor(
            windowWidth: double.nan, collapsedByUser: false),
        ChatPanelGeometry.railWidthFor(0),
      );
      expect(
        ChatPanelGeometry.widthFor(windowWidth: -5, collapsedByUser: false),
        ChatPanelGeometry.railWidth,
      );
    });
  });
}

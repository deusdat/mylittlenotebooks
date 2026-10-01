import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/app.dart';
import 'package:mylittlenotebooks/data/notebook_repository.dart';
import 'package:mylittlenotebooks/data/panel_state_store.dart';
import 'package:mylittlenotebooks/models/panel_geometry.dart';
import 'package:mylittlenotebooks/shell/nav_panel.dart';
import 'package:mylittlenotebooks/shell/nav_destination_tile.dart';

/// Shared harness for the widget-level suites.
Widget buildTestApp({bool preloadedCollapsed = false}) {
  final seeded = seededRepository();
  return App(
    preloadedCollapsed: preloadedCollapsed,
    store: InMemoryPanelStateStore(initialCollapsed: preloadedCollapsed),
    repo: seeded.repository,
    initialNotebooks: seeded.notebooks,
  );
}

/// Drives the app at an exact logical window size.
Future<void> pumpAtSize(
  WidgetTester tester,
  double width,
  double height, {
  bool preloadedCollapsed = false,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = Size(width, height);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(buildTestApp(preloadedCollapsed: preloadedCollapsed));
  await tester.pumpAndSettle();
}

double panelWidth(WidgetTester tester) =>
    tester.getSize(find.byType(NavPanel)).width;

/// Finds a destination by its label. The expanded panel renders a text label
/// rather than a tooltip, so `byTooltip` only works in the rail.
Finder tileWithLabel(String label) => find.byWidgetPredicate(
  (widget) => widget is NavDestinationTile && widget.label == label,
);

void main() {
  group('panel width (AC2)', () {
    testWidgets('is 20% of the window between 900 and 1600', (tester) async {
      await pumpAtSize(tester, 1200, 800);
      expect(panelWidth(tester), moreOrLessEquals(240));
      expect(panelWidth(tester), closeTo(1200 * 0.20, 0.001));
    });

    testWidgets('is 180 at the breakpoint', (tester) async {
      await pumpAtSize(tester, 900, 800);
      expect(panelWidth(tester), moreOrLessEquals(180));
    });

    testWidgets('clamps at 320 above 1600', (tester) async {
      await pumpAtSize(tester, 2400, 900);
      expect(panelWidth(tester), moreOrLessEquals(320));
    });

    testWidgets('never exceeds 20% at any tested width', (tester) async {
      for (final width in [900.0, 950.0, 1100.0, 1300.0, 1600.0, 1920.0]) {
        await pumpAtSize(tester, width, 800);
        expect(
          panelWidth(tester),
          lessThanOrEqualTo(width * 0.20 + 0.01),
          reason: 'panel exceeded 20% at $width px',
        );
      }
    });

    testWidgets('tracks a window resize without any listener', (tester) async {
      await pumpAtSize(tester, 1600, 800);
      expect(panelWidth(tester), moreOrLessEquals(320));

      tester.view.physicalSize = const Size(1000, 800);
      await tester.pumpAndSettle();
      expect(panelWidth(tester), moreOrLessEquals(200));

      tester.view.physicalSize = const Size(1400, 800);
      await tester.pumpAndSettle();
      expect(panelWidth(tester), moreOrLessEquals(280));
    });

    testWidgets('an unrelated rebuild at the same size is stable', (tester) async {
      await pumpAtSize(tester, 1200, 800);
      final before = panelWidth(tester);
      await tester.pump();
      await tester.pump();
      expect(panelWidth(tester), before);
    });
  });

  group('narrow windows (AC3, AC7)', () {
    testWidgets('below 900 the panel is a 56 px rail', (tester) async {
      await pumpAtSize(tester, 700, 800);
      expect(panelWidth(tester), moreOrLessEquals(PanelGeometry.railWidth));
    });

    testWidgets('narrowing does not open any overlay or modal', (
      tester,
    ) async {
      await pumpAtSize(tester, 1200, 800);
      tester.view.physicalSize = const Size(640, 800);
      await tester.pumpAndSettle();

      expect(find.byType(NavPanel), findsOneWidget);
      expect(panelWidth(tester), moreOrLessEquals(56));
      // A modal route would put a second Scaffold/dialog in the tree.
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(Drawer), findsNothing);
    });

    testWidgets('the centre page keeps a usable share down to 320 px', (
      tester,
    ) async {
      for (final width in [900.0, 700.0, 480.0, 320.0]) {
        await pumpAtSize(tester, width, 700);
        expect(tester.takeException(), isNull, reason: 'overflow at $width px');
        expect(panelWidth(tester), lessThan(width));
      }
    });
  });

  group('persistence of intent (AC8, AC9)', () {
    testWidgets('a preloaded collapsed state renders collapsed on the first frame', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1200, 800);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(buildTestApp(preloadedCollapsed: true));
      // Asserted immediately, with no settle: an async hydration path would
      // render the expanded panel here and snap to the rail a frame later.
      expect(panelWidth(tester), moreOrLessEquals(56));
    });

    testWidgets('the collapse control toggles and nothing else changes width', (
      tester,
    ) async {
      await pumpAtSize(tester, 1200, 800);
      expect(panelWidth(tester), moreOrLessEquals(240));

      await tester.tap(tileWithLabel('Collapse panel'));
      await tester.pumpAndSettle();
      expect(panelWidth(tester), moreOrLessEquals(56));

      await tester.tap(tileWithLabel('Expand panel'));
      await tester.pumpAndSettle();
      expect(panelWidth(tester), moreOrLessEquals(240));
    });
  });

  group('accessibility (AC6, AC19)', () {
    testWidgets('the rail exposes every destination with a semantic label', (
      tester,
    ) async {
      await pumpAtSize(tester, 700, 800);
      final tiles = tester.widgetList<NavDestinationTile>(
        find.byType(NavDestinationTile),
      );
      expect(tiles.length, greaterThan(1));
      for (final tile in tiles) {
        expect(tile.label, isNotEmpty);
      }
    });

    testWidgets('rail destinations carry a tooltip', (tester) async {
      await pumpAtSize(tester, 700, 800);
      expect(find.byTooltip('Add Notebook'), findsOneWidget);
      expect(find.byTooltip('Settings'), findsOneWidget);
    });

    testWidgets('every destination exposes a button semantics node', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpAtSize(tester, 1200, 800);

      final nodes = tester
          .widgetList<NavDestinationTile>(find.byType(NavDestinationTile))
          .length;
      expect(nodes, greaterThan(1));

      expect(
        find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.button == true,
        ),
        findsAtLeastNWidgets(nodes),
      );
      handle.dispose();
    });
  });

  group('platform keyboard shortcuts (AC16)', () {
    testWidgets('collapse shortcut toggles the panel', (tester) async {
      await pumpAtSize(tester, 1200, 800);
      expect(panelWidth(tester), moreOrLessEquals(240));

      final collapseKey = switch (defaultTargetPlatform) {
        TargetPlatform.macOS || TargetPlatform.iOS =>
          LogicalKeyboardKey.meta,
        _ => LogicalKeyboardKey.control,
      };

      await tester.sendKeyDownEvent(collapseKey);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyUpEvent(collapseKey);
      await tester.pumpAndSettle();

      expect(panelWidth(tester), moreOrLessEquals(56));
    });
  });
}
import 'package:flutter/foundation.dart';
import 'package:mylittlenotebooks/shell/form_factor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/app.dart';
import 'package:mylittlenotebooks/data/ai_config_repository.dart';
import 'package:mylittlenotebooks/data/notebook_repository.dart';
import 'package:mylittlenotebooks/data/panel_state_store.dart';
import 'package:mylittlenotebooks/models/notebook.dart';
import 'package:mylittlenotebooks/models/panel_geometry.dart';
import 'package:mylittlenotebooks/pages/notebook_detail_page.dart';
import 'package:mylittlenotebooks/pages/notebooks_home_page.dart';
import 'package:mylittlenotebooks/shell/nav_panel.dart';
import 'package:mylittlenotebooks/shell/nav_destination_tile.dart';
import 'test_note_env.dart';

/// Shared harness for the widget-level suites.
Widget buildTestApp({bool preloadedCollapsed = false}) {
  final seeded = seededRepository();
  return App(
    preloadedCollapsed: preloadedCollapsed,
    store: InMemoryPanelStateStore(initialCollapsed: preloadedCollapsed),
    repo: seeded.repository,
    initialNotebooks: seeded.notebooks,
    aiConfigs: InMemoryAiConfigRepository(),
    initialAiConfigs: const [],
    noteEnv: testNoteEnvironment(),
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
  // The shell docks on desktop and overlays on mobile. Most tests exercise the
  // desktop path; the overlay group overrides to a mobile platform.
  setUp(() => formFactorOverride = TargetPlatform.macOS);
  tearDown(() => formFactorOverride = null);

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

  group('narrow desktop windows (AC3, AC7)', () {
    testWidgets('below 900 the panel narrows, it does not collapse to a rail', (
      tester,
    ) async {
      await pumpAtSize(tester, 700, 800);
      // Desktop docks whatever the width; it shrinks rather than collapsing.
      expect(panelWidth(tester), moreOrLessEquals(180));
      expect(panelWidth(tester), greaterThan(PanelGeometry.railWidth));
    });

    testWidgets('narrowing does not open any overlay or modal', (
      tester,
    ) async {
      await pumpAtSize(tester, 1200, 800);
      tester.view.physicalSize = const Size(640, 800);
      await tester.pumpAndSettle();

      expect(find.byType(NavPanel), findsOneWidget);
      expect(panelWidth(tester), greaterThan(PanelGeometry.railWidth));
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

    testWidgets('a dockable window never shows the overlay', (tester) async {
      await pumpAtSize(tester, 1200, 800);
      // The panel is already expanded and docked; collapsing shows the rail,
      // and there is only ever one NavPanel.
      await tester.tap(tileWithLabel('Collapse panel'));
      await tester.pumpAndSettle();
      expect(find.byType(NavPanel), findsOneWidget);
      // Expanding again docks it in place, still one panel.
      await tester.tap(tileWithLabel('Expand panel'));
      await tester.pumpAndSettle();
      expect(find.byType(NavPanel), findsOneWidget);
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

  group('mobile overlay (FR15, AC21-AC25)', () {
    // Mobile is the only form factor that overlays.
    setUp(() => formFactorOverride = TargetPlatform.android);
    tearDown(() => formFactorOverride = TargetPlatform.macOS);

    testWidgets('Expand panel opens the overlay', (tester) async {
      await pumpAtSize(tester, 700, 800);

      // One NavPanel in the layout (the rail).
      expect(find.byType(NavPanel), findsOneWidget);
      await tester.tap(tileWithLabel('Expand panel'));
      await tester.pumpAndSettle();

      // A second NavPanel is now the overlay, and it renders text labels (only
      // the expanded form does; the rail is icon-only).
      expect(find.byType(NavPanel), findsNWidgets(2));
      expect(find.text('Add Notebook'), findsOneWidget);
    });

    testWidgets('Escape dismisses the overlay without navigating back', (
      tester,
    ) async {
      await pumpAtSize(tester, 700, 800);
      await tester.tap(tileWithLabel('Expand panel'));
      await tester.pumpAndSettle();
      expect(find.byType(NavPanel), findsNWidgets(2));

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.byType(NavPanel), findsOneWidget);
    });

    testWidgets('choosing a destination closes the overlay and navigates', (
      tester,
    ) async {
      await pumpAtSize(tester, 700, 800);
      await tester.tap(tileWithLabel('Expand panel'));
      await tester.pumpAndSettle();

      await tester.tap(tileWithLabel('Notebook 2').first);
      await tester.pumpAndSettle();

      expect(find.byType(NavPanel), findsOneWidget);
      expect(find.text('Notebook 2'), findsWidgets);
    });
  });

  group('accessibility (AC6, AC19)', () {
    // Rail affordances (tooltips, icon-only tiles) are the mobile form.
    setUp(() => formFactorOverride = TargetPlatform.android);
    tearDown(() => formFactorOverride = TargetPlatform.macOS);

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

  group('route pushes are idempotent (FR9, AC13)', () {
    // A `push` appends, and every notebook page carries a stable per-notebook key
    // so back can restore scroll position (AC13). A repeated push therefore puts
    // two pages with the same key into one Navigator, which Flutter rejects:
    //
    //   Failed assertion: line 4096: '!keyReservation.contains(key)'
    //
    // One stray double-click reaches it, because both taps are delivered before
    // the frame that would swap the panel into detail level.
    Future<List<Notebook>> pumpSeeded(WidgetTester tester) async {
      final seeded = seededRepository();
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1200, 800);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(App(
        preloadedCollapsed: false,
        store: InMemoryPanelStateStore(),
        repo: seeded.repository,
        initialNotebooks: seeded.notebooks,
        aiConfigs: InMemoryAiConfigRepository(),
        initialAiConfigs: const [],
      noteEnv: testNoteEnvironment(),
      ));
      await tester.pumpAndSettle();
      return seeded.notebooks;
    }

    testWidgets('a double-click on one notebook does not duplicate its page', (
      tester,
    ) async {
      final notebooks = await pumpSeeded(tester);
      final label = notebooks.first.title;

      // Both taps before a frame is built — what a trackpad double-click does.
      await tester.tap(tileWithLabel(label));
      await tester.tap(tileWithLabel(label));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(NotebookDetailPage), findsOneWidget);
    });

    testWidgets('back, then the same notebook again, still works', (
      tester,
    ) async {
      final notebooks = await pumpSeeded(tester);
      final label = notebooks.first.title;

      await tester.tap(tileWithLabel(label));
      await tester.pumpAndSettle();
      expect(find.byType(NotebookDetailPage), findsOneWidget);

      // Escape is the shell's back affordance (FR11/AC16).
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(NotebookDetailPage), findsNothing,
          reason: 'Escape must pop back to the list');
      expect(find.byType(NotebooksHomePage), findsOneWidget);
      expect(tileWithLabel(label), findsOneWidget, reason: 'back to the list');

      await tester.tap(tileWithLabel(label));
      await tester.pumpAndSettle();

      expect(find.byType(NotebookDetailPage), findsOneWidget,
          reason: 'the guard must not latch: re-entering after back is a new '
              'navigation, not a repeat');
    });

    testWidgets('a rapid tap on two different notebooks navigates', (
      tester,
    ) async {
      final notebooks = await pumpSeeded(tester);

      // Two different targets with no frame between them. A debounce-based fix
      // would swallow the second and land on the wrong notebook; this proves the
      // guard compares locations rather than swallowing repeats.
      await tester.tap(tileWithLabel(notebooks[0].title));
      await tester.tap(tileWithLabel(notebooks[1].title));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final detail = tester.widget<NotebookDetailPage>(
        find.byType(NotebookDetailPage),
      );
      expect(detail.notebookId, notebooks[1].id,
          reason: 'the last tap wins');
    });

    testWidgets('three taps in a row leave exactly one page', (tester) async {
      final notebooks = await pumpSeeded(tester);
      final label = notebooks.first.title;

      await tester.tap(tileWithLabel(label));
      await tester.tap(tileWithLabel(label));
      await tester.tap(tileWithLabel(label));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(NotebookDetailPage), findsOneWidget);
    });

    testWidgets('Add Notebook still creates and opens the new notebook', (
      tester,
    ) async {
      await pumpSeeded(tester);
      final before = tester.widgetList<NavDestinationTile>(
        find.byType(NavDestinationTile),
      ).length;

      await tester.tap(tileWithLabel('Add Notebook'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(NotebookDetailPage), findsOneWidget);
      expect(
        tester.widgetList<NavDestinationTile>(find.byType(NavDestinationTile)).length,
        greaterThanOrEqualTo(before),
      );
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
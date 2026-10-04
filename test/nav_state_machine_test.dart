import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mylittlenotebooks/app.dart';
import 'package:mylittlenotebooks/data/ai_config_repository.dart';
import 'package:mylittlenotebooks/data/notebook_repository.dart';
import 'package:mylittlenotebooks/data/panel_state_store.dart';
import 'package:mylittlenotebooks/models/nav_level.dart';
import 'package:mylittlenotebooks/models/notebook_section.dart';
import 'package:mylittlenotebooks/shell/nav_destination_tile.dart';
import 'package:mylittlenotebooks/shell/nav_panel.dart';

({App app, NotebookRepository repo}) buildTestApp({
  bool collapsed = false,
  int seedCount = 3,
}) {
  final repository = InMemoryNotebookRepository();
  for (var i = 0; i < seedCount; i++) {
    repository.create();
  }
  return (
    app: App(
      preloadedCollapsed: collapsed,
      store: InMemoryPanelStateStore(initialCollapsed: collapsed),
      repo: repository,
      initialNotebooks: repository.list(),
      aiConfigs: InMemoryAiConfigRepository(),
      initialAiConfigs: const [],
    ),
    repo: repository,
  );
}

Finder tileWithLabel(String label) => find.byWidgetPredicate(
  (widget) => widget is NavDestinationTile && widget.label == label,
);

/// Reads the live scroll offset of the notebook list.
///
/// `ListView.builder` owns its controller internally, so `widget.controller` is
/// null; the position has to come from the Scrollable's state.
double scrollOffsetOf(WidgetTester tester) {
  final scrollable = find.descendant(
    of: find.byKey(const PageStorageKey<String>('notebook-list')),
    matching: find.byType(Scrollable),
  );
  return tester.state<ScrollableState>(scrollable).position.pixels;
}

Future<void> pumpAt(WidgetTester tester, double width) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = Size(width, 800);
  addTearDown(tester.view.reset);
}

void main() {
  group('navLevelFrom — pure, no router required', () {
    test('reads the detail level off a notebook path', () {
      expect(navLevelFrom(Uri.parse('/')), const NavLevelList());
      expect(navLevelFrom(Uri.parse('/settings')), const NavLevelList());
      expect(
        navLevelFrom(Uri.parse('/notebook/nb-3')),
        const NavLevelDetail('nb-3'),
      );
    });

    test('unknown shapes fall back to the list level', () {
      expect(navLevelFrom(Uri.parse('/whatever')), const NavLevelList());
      expect(navLevelFrom(Uri.parse('/notebook')), const NavLevelList());
      expect(navLevelFrom(Uri.parse('')), const NavLevelList());
      expect(
        navLevelFrom(Uri.parse('/notebook/nb-3/extra')),
        const NavLevelDetail('nb-3'),
      );
    });
  });

  group('drill-down and back (AC12, AC13, AC14)', () {
    testWidgets('opening a notebook swaps the panel to detail content', (
      tester,
    ) async {
      await pumpAt(tester, 1200);
      await tester.pumpWidget(buildTestApp().app);
      await tester.pumpAndSettle();

      expect(tileWithLabel('Add Notebook'), findsOneWidget);
      expect(tileWithLabel('Notebook 1'), findsOneWidget);

      await tester.tap(tileWithLabel('Notebook 2'));
      await tester.pumpAndSettle();

      // Neither the list nor Add Notebook is present inside a notebook.
      expect(tileWithLabel('Add Notebook'), findsNothing);
      expect(tileWithLabel('Notebook 1'), findsNothing);
      expect(tileWithLabel('Notebook 2'), findsNothing);
      expect(tileWithLabel('Back to notebooks'), findsOneWidget);
    });

    testWidgets('detail navigation lists the notebook sections', (tester) async {
      await pumpAt(tester, 1200);
      await tester.pumpWidget(buildTestApp().app);
      await tester.pumpAndSettle();

      await tester.tap(tileWithLabel('Notebook 1'));
      await tester.pumpAndSettle();

      for (final section in notebookSections) {
        expect(tileWithLabel(section.label), findsOneWidget);
      }
      expect(find.text('Notebook 1'), findsWidgets);
    });

    testWidgets('exactly one section is enabled today', (tester) async {
      await pumpAt(tester, 1200);
      await tester.pumpWidget(buildTestApp().app);
      await tester.pumpAndSettle();
      await tester.tap(tileWithLabel('Notebook 1'));
      await tester.pumpAndSettle();

      final tiles = tester
          .widgetList<NavDestinationTile>(find.byType(NavDestinationTile))
          .where((tile) => notebookSections.any((s) => s.label == tile.label))
          .toList();
      expect(tiles.where((tile) => tile.enabled).length, 1);
      expect(tiles.firstWhere((tile) => tile.enabled).label, 'Overview');
    });

    testWidgets('back restores the list and Add Notebook', (tester) async {
      await pumpAt(tester, 1200);
      await tester.pumpWidget(buildTestApp().app);
      await tester.pumpAndSettle();

      await tester.tap(tileWithLabel('Notebook 1'));
      await tester.pumpAndSettle();
      await tester.tap(tileWithLabel('Back to notebooks'));
      await tester.pumpAndSettle();

      expect(tileWithLabel('Add Notebook'), findsOneWidget);
      expect(tileWithLabel('Notebook 1'), findsOneWidget);
      expect(tileWithLabel('Back to notebooks'), findsNothing);
    });

    testWidgets('Escape navigates back like the on-screen control', (
      tester,
    ) async {
      await pumpAt(tester, 1200);
      await tester.pumpWidget(buildTestApp().app);
      await tester.pumpAndSettle();

      await tester.tap(tileWithLabel('Notebook 1'));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(tileWithLabel('Add Notebook'), findsOneWidget);
    });

    testWidgets('nothing is marked selected at the list level', (tester) async {
      await pumpAt(tester, 1200);
      await tester.pumpWidget(buildTestApp().app);
      await tester.pumpAndSettle();

      await tester.tap(tileWithLabel('Notebook 1'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      final listTiles = tester
          .widgetList<NavDestinationTile>(find.byType(NavDestinationTile))
          .where((tile) => tile.label.startsWith('Notebook'))
          .toList();
      expect(listTiles, isNotEmpty);
      expect(listTiles.every((tile) => !tile.selected), isTrue);
    });

    testWidgets('scroll position survives a round trip', (tester) async {
      await pumpAt(tester, 1200);
      await tester.pumpWidget(buildTestApp(seedCount: 40).app);
      await tester.pumpAndSettle();

      // 40 seeded notebooks so the list genuinely overflows its viewport;
      // otherwise this test would pass without proving anything (plan R5).
      await tester.drag(
        find.byKey(const PageStorageKey<String>('notebook-list')),
        const Offset(0, -400),
      );
      await tester.pumpAndSettle();
      final before = scrollOffsetOf(tester);
      expect(before, greaterThan(0));

      // Navigate programmatically: after scrolling, the first notebook is off
      // screen and cannot be tapped. The assertion under test is PageStorage
      // restoration across the route round trip, not the tap.
      final router = GoRouter.of(tester.element(find.byType(NavPanel)));
      router.push('/notebook/nb-30');
      await tester.pumpAndSettle();
      expect(tileWithLabel('Back to notebooks'), findsOneWidget);

      router.pop();
      await tester.pumpAndSettle();

      expect(tileWithLabel('Add Notebook'), findsOneWidget);
      expect(scrollOffsetOf(tester), greaterThan(0));
    });
  });

  group('settings (AC15)', () {
    testWidgets('is reachable from the list and returns there', (tester) async {
      await pumpAt(tester, 1200);
      await tester.pumpWidget(buildTestApp().app);
      await tester.pumpAndSettle();

      await tester.tap(tileWithLabel('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsWidgets);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tileWithLabel('Add Notebook'), findsOneWidget);
    });

    testWidgets('is reachable from inside a notebook and returns there', (
      tester,
    ) async {
      await pumpAt(tester, 1200);
      await tester.pumpWidget(buildTestApp().app);
      await tester.pumpAndSettle();

      await tester.tap(tileWithLabel('Notebook 1'));
      await tester.pumpAndSettle();
      await tester.tap(tileWithLabel('Settings'));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      // Returns to the detail level, not to the list.
      expect(tileWithLabel('Back to notebooks'), findsOneWidget);
      expect(tileWithLabel('Add Notebook'), findsNothing);
    });
  });

  group('route safety (AC17)', () {
    testWidgets('an unknown notebook id redirects to the list', (tester) async {
      await pumpAt(tester, 1200);
      await tester.pumpWidget(buildTestApp().app);
      await tester.pumpAndSettle();

      final router = GoRouter.of(tester.element(find.byType(NavPanel)));
      router.go('/notebook/does-not-exist');
      await tester.pumpAndSettle();

      expect(find.text('Page not found'), findsNothing);
      expect(tileWithLabel('Add Notebook'), findsOneWidget);
    });

    testWidgets('the app starts at the list level', (tester) async {
      await pumpAt(tester, 1200);
      await tester.pumpWidget(buildTestApp().app);
      await tester.pumpAndSettle();

      expect(tileWithLabel('Add Notebook'), findsOneWidget);
      expect(tileWithLabel('Back to notebooks'), findsNothing);
    });
  });
}

/// Placeholder used to build a long seed list for the scroll test.
class NotebookStub {
  final int index;
  const NotebookStub(this.index);
}
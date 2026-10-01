import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/app.dart';
import 'package:mylittlenotebooks/data/notebook_repository.dart';
import 'package:mylittlenotebooks/data/panel_state_store.dart';
import 'package:mylittlenotebooks/shell/nav_destination_tile.dart';

({App app, NotebookRepository repo}) buildTestApp({int seedCount = 3}) {
  final repository = InMemoryNotebookRepository();
  for (var i = 0; i < seedCount; i++) {
    repository.create();
  }
  return (
    app: App(
      preloadedCollapsed: false,
      store: InMemoryPanelStateStore(),
      repo: repository,
      initialNotebooks: repository.list(),
    ),
    repo: repository,
  );
}

Finder tileWithLabel(String label) => find.byWidgetPredicate(
  (widget) => widget is NavDestinationTile && widget.label == label,
);

void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized();
    expect(view, isNotNull);
  });

  Future<void> pumpApp(WidgetTester tester, {int seedCount = 3}) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(buildTestApp(seedCount: seedCount).app);
    await tester.pumpAndSettle();
  }

  group('Add Notebook (AC10)', () {
    testWidgets('creates, appends at the end, and opens — with no dialog', (
      tester,
    ) async {
      final harness = buildTestApp();
      await tester.pumpWidget(harness.app);
      await tester.pumpAndSettle();

      final before = harness.repo.list();
      expect(before, hasLength(3));

      await tester.tap(tileWithLabel('Add Notebook'));
      await tester.pumpAndSettle();

      final after = harness.repo.list();
      expect(after, hasLength(4));
      expect(after.last.title, 'Notebook 4');
      // Creation order, oldest first, newest appended last.
      expect(after.map((n) => n.title).toList(), [
        'Notebook 1',
        'Notebook 2',
        'Notebook 3',
        'Notebook 4',
      ]);

      // A naming dialog would have interrupted this.
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(TextField), findsNothing);

      // And it opened: the panel swapped to detail content.
      expect(tileWithLabel('Back to notebooks'), findsOneWidget);
      expect(find.text('Notebook 4'), findsWidgets);
    });

    testWidgets('is the first destination in the panel', (tester) async {
      await pumpApp(tester);
      final tiles = tester
          .widgetList<NavDestinationTile>(find.byType(NavDestinationTile))
          .toList();
      expect(tiles.first.label, 'Collapse panel');
      expect(tiles[1].label, 'Add Notebook');
    });
  });

  group('selection (AC11)', () {
    testWidgets('activating a notebook opens it', (tester) async {
      await pumpApp(tester);

      await tester.tap(tileWithLabel('Notebook 2'));
      await tester.pumpAndSettle();

      expect(find.text('Notebook 2'), findsWidgets);
      expect(tileWithLabel('Add Notebook'), findsNothing);
    });
  });

  group('ordering and empty state (FR8)', () {
    testWidgets('seeded notebooks render in creation order', (tester) async {
      await pumpApp(tester, seedCount: 5);
      final titles = tester
          .widgetList<NavDestinationTile>(find.byType(NavDestinationTile))
          .map((tile) => tile.label)
          .where((label) => label.startsWith('Notebook'))
          .toList();
      expect(titles, ['Notebook 1', 'Notebook 2', 'Notebook 3', 'Notebook 4', 'Notebook 5']);
    });

    testWidgets('the empty state renders with no notebooks', (tester) async {
      await pumpApp(tester, seedCount: 0);
      expect(find.textContaining('No notebooks yet'), findsOneWidget);
      expect(tileWithLabel('Add Notebook'), findsOneWidget);
    });
  });

  group('repository', () {
    test('seeds three notebooks with stable titles', () {
      final seeded = seededRepository();
      expect(seeded.notebooks.map((n) => n.title).toList(), [
        'Notebook 1',
        'Notebook 2',
        'Notebook 3',
      ]);
    });

    test('appends newest last and keeps ids unique', () {
      final repo = InMemoryNotebookRepository();
      final ids = <String>{};
      for (var i = 0; i < 10; i++) {
        final notebook = repo.create();
        expect(ids.add(notebook.id), isTrue, reason: 'ids must be unique');
      }
      expect(repo.list().last.title, 'Notebook 10');
    });

    test('exists reflects the repository contents', () {
      final repo = InMemoryNotebookRepository();
      expect(repo.exists('nope'), isFalse);
      final created = repo.create();
      expect(repo.exists(created.id), isTrue);
    });

    test('list() returns creation order and is not re-sorted per call', () {
      final repo = InMemoryNotebookRepository();
      repo.create();
      repo.create();
      final first = repo.list().map((n) => n.id).toList();
      final second = repo.list().map((n) => n.id).toList();
      expect(second, first);
    });
  });
}
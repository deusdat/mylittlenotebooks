import 'package:mylittlenotebooks/shell/form_factor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/app.dart';
import 'package:mylittlenotebooks/data/ai_config_repository.dart';
import 'package:mylittlenotebooks/data/notebook_repository.dart';
import 'package:mylittlenotebooks/data/panel_state_store.dart';
import 'package:mylittlenotebooks/models/panel_geometry.dart';
import 'package:mylittlenotebooks/pages/note_editor_page.dart';
import 'package:mylittlenotebooks/pages/notes_overview_page.dart';
import 'package:mylittlenotebooks/shell/nav_destination_tile.dart';
import 'package:mylittlenotebooks/shell/nav_panel.dart';

import 'test_note_env.dart';

NavDestinationTile sectionTile(WidgetTester tester, String label) =>
    tester.widget<NavDestinationTile>(
        find.widgetWithText(NavDestinationTile, label));

/// Regression: opening a note used to replace the navigation stack (`go`), so
/// Back had nothing to pop and did nothing. Notes now `push`, so Back returns
/// to the notes section. And the Notes section must only highlight when it is
/// actually selected — `/notebook/<id>` must not match on the substring `/note`.
void main() {
  // Desktop (docked panel) is the default under test; narrower widths are
  // covered explicitly in app_shell_widget_test.
  setUp(() => formFactorOverride = TargetPlatform.macOS);
  tearDown(() => formFactorOverride = null);

  Future<void> pumpApp(WidgetTester tester, {double width = 1400}) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = Size(width, 900);
    addTearDown(tester.view.reset);

    final seeded = seededRepository();
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
  }

  Future<void> openNotesSectionAndEditor(WidgetTester tester) async {
    await tester.tap(find.text('Notebook 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Notes'));
    await tester.pumpAndSettle();
    expect(find.byType(NotesOverviewPage), findsOneWidget);

    // The centre button, not the nav panel's Add note.
    await tester.tap(find.descendant(
      of: find.byType(NotesOverviewPage),
      matching: find.text('Add note'),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(NoteEditorPage), findsOneWidget);
  }

  testWidgets('the panel stays expanded across navigation', (tester) async {
    await pumpApp(tester);
    final expanded = tester.getSize(find.byType(NavPanel)).width;
    expect(expanded, greaterThan(PanelGeometry.railWidth),
        reason: 'a dockable window starts expanded');

    await tester.tap(find.text('Notebook 1'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(NavPanel)).width, expanded,
        reason: 'navigating to a notebook must not collapse the panel');

    await tester.tap(find.text('Notes'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(NavPanel)).width, expanded,
        reason: 'selecting Notes must not collapse the panel');
  });

  testWidgets('the editor back arrow returns to the notes section',
      (tester) async {
    await pumpApp(tester);
    await openNotesSectionAndEditor(tester);

    await tester.tap(find.byTooltip('Back to notes'));
    await tester.pumpAndSettle();

    expect(find.byType(NotesOverviewPage), findsOneWidget);
    expect(find.byType(NoteEditorPage), findsNothing);
  });

  testWidgets('the Notes section is not highlighted on the notebook overview',
      (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Notebook 1'));
    await tester.pumpAndSettle();

    // `/notebook/<id>` must not be read as the Notes section — a substring
    // match on `/note` wrongly selected it on every notebook page.
    expect(sectionTile(tester, 'Notes').selected, isFalse);
    expect(sectionTile(tester, 'Overview').selected, isTrue);

    await tester.tap(find.text('Notes'));
    await tester.pumpAndSettle();
    expect(sectionTile(tester, 'Notes').selected, isTrue);
    expect(sectionTile(tester, 'Overview').selected, isFalse);
  });

  testWidgets('the chat panel expands on a narrow desktop window',
      (tester) async {
    // Regression: the chat panel used to force a rail below ~917 px, so the
    // expand toggle changed the content inside a 48 px box and overflowed.
    await pumpApp(tester, width: 800);
    await openNotesSectionAndEditor(tester);

    expect(find.text('Ask about this note…'), findsNothing);
    await tester.tap(find.byTooltip('Expand chat'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull, reason: 'no overflow on expand');
    expect(find.text('Ask about this note…'), findsOneWidget);
  });

  testWidgets('the panel Back control returns to the notes section, not home',
      (tester) async {
    await pumpApp(tester);
    await openNotesSectionAndEditor(tester);

    await tester.tap(find.text('Back to notebooks'));
    await tester.pumpAndSettle();

    expect(find.byType(NotesOverviewPage), findsOneWidget,
        reason: 'Back from a note must land on the notebook section');
    expect(find.byType(NoteEditorPage), findsNothing);
  });
}

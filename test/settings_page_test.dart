import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/data/ai_config_repository.dart';
import 'package:mylittlenotebooks/pages/settings_page.dart';
import 'package:mylittlenotebooks/state/ai_configs_state.dart';
import 'package:mylittlenotebooks/state/use_ai_configs_state.dart';
import 'package:utopia_hooks/utopia_hooks.dart';

/// The Settings page contract (settings-for-ai AC17–AC20).
void main() {
  Widget harness(AiConfigRepository repo) => HookProviderContainerWidget(
        {
          AiConfigsState: () =>
              useAiConfigsState(repo: repo, preloaded: repo.list()),
        },
        child: const MaterialApp(home: Scaffold(body: SettingsPage())),
      );

  Future<void> openAdd(WidgetTester tester) async {
    await tester.tap(find.text('Add endpoint'));
    await tester.pumpAndSettle();
  }

  Future<void> fillForm(
    WidgetTester tester, {
    String? name,
    String? endpoint,
    String? token,
  }) async {
    final fields = find.byType(TextFormField);
    if (name != null) await tester.enterText(fields.at(0), name);
    if (endpoint != null) await tester.enterText(fields.at(1), endpoint);
    if (token != null) await tester.enterText(fields.at(2), token);
  }

  group('AC17 — list, empty state, add', () {
    testWidgets('renders the empty state, then a created tuple', (tester) async {
      final repo = InMemoryAiConfigRepository();
      await tester.pumpWidget(harness(repo));

      expect(find.text('No AI endpoints yet'), findsOneWidget);

      await openAdd(tester);
      await fillForm(tester, name: 'Local Ollama', endpoint: 'http://localhost:11434/v1');
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();

      expect(repo.list(), hasLength(1));
      expect(find.text('Local Ollama'), findsOneWidget);
      expect(find.text('http://localhost:11434/v1'), findsOneWidget);
      expect(find.text('No AI endpoints yet'), findsNothing);
    });
  });

  group('AC18 — validation and token presence', () {
    testWidgets('blocks an empty name and a non-URL endpoint', (tester) async {
      final repo = InMemoryAiConfigRepository();
      await tester.pumpWidget(harness(repo));
      await openAdd(tester);

      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a name'), findsOneWidget);
      expect(find.text('Enter an endpoint URL'), findsOneWidget);
      expect(repo.list(), isEmpty);

      await fillForm(tester, name: 'X', endpoint: 'not a url');
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();
      expect(find.text('Enter an absolute http(s) URL'), findsOneWidget);
      expect(repo.list(), isEmpty);
    });

    testWidgets('token is optional and reflected as presence only',
        (tester) async {
      final repo = InMemoryAiConfigRepository();
      await tester.pumpWidget(harness(repo));

      await openAdd(tester);
      await fillForm(tester, name: 'No token', endpoint: 'http://a/v1');
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('No token'), findsOneWidget);

      await openAdd(tester);
      await fillForm(
        tester,
        name: 'With token',
        endpoint: 'http://b/v1',
        token: 'sk-secret',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Token set'), findsOneWidget);
      // The secret itself is never rendered.
      expect(find.text('sk-secret'), findsNothing);
    });
  });

  group('AC19 — permanent delete confirmation', () {
    testWidgets('names the tuple, and every dismissal changes nothing',
        (tester) async {
      final repo = InMemoryAiConfigRepository();
      await repo.create(
        label: 'Shared',
        endpoint: 'http://a/v1',
        shared: true,
        token: 't',
      );
      await tester.pumpWidget(harness(repo));

      await tester.tap(find.byTooltip('Delete Shared'));
      await tester.pumpAndSettle();
      expect(find.textContaining('permanently deletes "Shared"'), findsOneWidget);
      expect(find.textContaining('other devices'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(repo.list(), hasLength(1));
      expect(find.text('Shared'), findsOneWidget);

      await tester.tap(find.byTooltip('Delete Shared'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(repo.list(), isEmpty);
      expect(find.text('No AI endpoints yet'), findsOneWidget);
    });
  });

  group('AC20 — accessibility', () {
    testWidgets('controls carry labels and the modal closes on Escape',
        (tester) async {
      final repo = InMemoryAiConfigRepository();
      await repo.create(
        label: 'Shared',
        endpoint: 'http://a/v1',
        shared: false,
      );
      await tester.pumpWidget(harness(repo));

      expect(find.byTooltip('Edit Shared'), findsOneWidget);
      expect(find.byTooltip('Delete Shared'), findsOneWidget);
      expect(find.text('Add endpoint'), findsOneWidget);

      await tester.tap(find.byTooltip('Delete Shared'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextButton, 'Delete'), findsNothing);
      expect(repo.list(), hasLength(1));
    });
  });
}

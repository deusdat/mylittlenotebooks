import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/data/panel_state_store.dart';
import 'package:mylittlenotebooks/state/panel_state.dart';
import 'package:mylittlenotebooks/state/use_panel_state.dart';
import 'package:utopia_hooks/utopia_hooks.dart';

/// Hook tests with no widget tree, using the package's `SimpleHookContext`
/// harness (spec NFR5). `ProviderContainer` is not involved and neither is a
/// widget binding.
void main() {
  late InMemoryPanelStateStore store;
  late SimpleHookContext<PanelState> context;

  PanelState build({required bool preloaded}) {
    context = SimpleHookContext(
      () => usePanelState(preloaded: preloaded, store: store),
    );
    addTearDown(context.dispose);
    return context.value;
  }

  setUp(() {
    store = InMemoryPanelStateStore();
  });

  test('the default intent is expanded', () {
    final state = build(preloaded: false);
    expect(state.collapsedByUser, isFalse);
  });

  test('the preloaded value seeds the first frame synchronously', () {
    // This is the assertion that distinguishes preloading in main() from an
    // async hook: no pump, no settle, no waitUntil — the value is simply there.
    final state = build(preloaded: true);
    expect(state.collapsedByUser, isTrue);
  });

  test('toggleCollapsed flips the intent and writes once', () {
    final state = build(preloaded: false);
    expect(state.toggleCollapsed, isNotNull);

    context.value.toggleCollapsed();
    context.rebuild();

    expect(context.value.collapsedByUser, isTrue);
    expect(store.writeCount, 1);
    expect(store.lastWritten, isTrue);
  });

  test('toggling twice returns to the original value', () {
    build(preloaded: false);

    context.value.toggleCollapsed();
    context.rebuild();
    context.value.toggleCollapsed();
    context.rebuild();

    expect(context.value.collapsedByUser, isFalse);
    expect(store.writeCount, 2);
  });

  test('the store receives only the collapsed boolean', () {
    // Nothing about width or presentation is written: there is no such state to
    // write (spec FR5).
    build(preloaded: false);
    context.value.toggleCollapsed();
    context.rebuild();

    expect(store.writeCount, 1);
  });

  test('a rebuilt provider with no keys preserves user intent', () {
    build(preloaded: false);

    context.value.toggleCollapsed();
    context.rebuild();
    context.rebuild();
    context.rebuild();

    expect(context.value.collapsedByUser, isTrue);
  });

  test('waitUntil observes a toggle', () async {
    build(preloaded: false);

    context.value.toggleCollapsed();
    await context.waitUntil((state) => state.collapsedByUser);

    expect(context.value.collapsedByUser, isTrue);
  });
}
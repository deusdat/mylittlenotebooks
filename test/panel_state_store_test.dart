import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/data/panel_state_store.dart';
import 'package:mylittlenotebooks/data/prefs_panel_state_store.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// Points the plugin at an in-memory platform so the suite never touches a
/// platform channel.
void useInMemoryPlatform([Map<String, Object> initialValues = const {}]) {
  SharedPreferencesAsyncPlatform.instance = initialValues.isEmpty
      ? InMemorySharedPreferencesAsync.empty()
      : InMemorySharedPreferencesAsync.withData(initialValues);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => useInMemoryPlatform());

  group('PrefsPanelStateStore', () {
    test('a missing key reads as the expanded default', () async {
      expect(await PrefsPanelStateStore().readCollapsed(), isFalse);
    });

    test('round-trips a written value', () async {
      final store = PrefsPanelStateStore();
      await store.writeCollapsed(true);
      expect(await store.readCollapsed(), isTrue);

      await store.writeCollapsed(false);
      expect(await store.readCollapsed(), isFalse);
    });

    test('a restored value is read back by a fresh store instance', () async {
      await PrefsPanelStateStore().writeCollapsed(true);
      expect(await PrefsPanelStateStore().readCollapsed(), isTrue);
    });

    test('re-writing replaces rather than accumulating', () async {
      final store = PrefsPanelStateStore();
      await store.writeCollapsed(true);
      await store.writeCollapsed(false);
      expect(await store.readCollapsed(), isFalse);
    });

    test('a wrongly-typed stored value degrades rather than throwing', () async {
      // A corrupt preference must never stop the app from opening: the store
      // swallows the platform type error and falls back to expanded.
      useInMemoryPlatform({PrefsPanelStateStore.collapsedKey: 'yes'});
      expect(await PrefsPanelStateStore().readCollapsed(), isFalse);
    });

    test('uses a single documented key', () {
      // One boolean under one key: there is no versioned document and nothing to
      // migrate, because there is no width to store (spec FR5).
      expect(PrefsPanelStateStore.collapsedKey, 'nav_panel.collapsed');
    });
  });

  group('InMemoryPanelStateStore', () {
    test('matches the contract', () async {
      final memory = InMemoryPanelStateStore();
      expect(await memory.readCollapsed(), isFalse);
      await memory.writeCollapsed(true);
      expect(await memory.readCollapsed(), isTrue);
      expect(memory.writeCount, 1);
    });
  });
}
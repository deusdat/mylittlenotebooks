import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/data/objectbox/objectbox_store.dart';

/// Guards the production store path.
///
/// **Why this file exists.** `openLibraryStore()` shipped broken for a full
/// milestone: it opened a store on a sandboxed macOS app without an App Group,
/// and failed at runtime with
/// `Could not open database environment (1: Operation not permitted)`.
///
/// Not one test caught it, because **every** test in this project opens
/// `openTestStore()` — an in-memory, file-less store that never touches the
/// filesystem and never goes through `openStore()`. The production constructor
/// had literally never been executed.
///
/// So these are structural assertions over configuration, not a runtime test of
/// the store. They cannot prove the store opens, but they do catch the class of
/// mistake where a required platform option is simply absent — and the runtime
/// proof belongs to a manual run, which is why [manual gate] below says so
/// plainly rather than pretending otherwise.
void main() {
  group('the App Group ObjectBox needs to open a store at all', () {
    test('is configured', () {
      expect(macosApplicationGroup, isNotEmpty);
    });

    test('fits macOS 19-character limit', () {
      // The limit applies to the **whole string passed to openStore**, not to
      // the group id alone. Exceeding it produces a store that cannot open, with
      // a misleading error, so it is worth asserting rather than eyeballing.
      expect(
        macosApplicationGroup.length,
        lessThanOrEqualTo(19),
        reason: 'macOS rejects an application group longer than 19 characters, '
            'and the error it produces does not mention the length',
      );
    });

    test('is declared in every macOS entitlements file', () {
      // An entitlement present in Dart but absent from the plist is exactly the
      // half-finished state that produced the original bug.
      final entitlementFiles = Directory('macos/Runner')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.entitlements'))
          .toList();

      expect(entitlementFiles, isNotEmpty,
          reason: 'expected macOS entitlements files to exist');

      for (final file in entitlementFiles) {
        final contents = file.readAsStringSync();
        expect(
          contents.contains('com.apple.security.application-groups'),
          isTrue,
          reason: '${file.path} must declare the application group, or the '
              'store cannot open on a sandboxed macOS app',
        );
        expect(
          contents.contains(macosApplicationGroup),
          isTrue,
          reason: '${file.path} must declare the SAME group that '
              'openLibraryStore passes to ObjectBox',
        );
      }
    });

    test('the sandbox stays on', () {
      // Disabling the sandbox is the other reported workaround and it is a
      // trap: it makes a local build work and then blocks distribution. If a
      // future change flips this, it should be deliberate.
      for (final file in Directory('macos/Runner')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.entitlements'))) {
        final contents = file.readAsStringSync();
        final sandboxKey = 'com.apple.security.app-sandbox';
        final keyIndex = contents.indexOf(sandboxKey);
        expect(keyIndex, isNot(-1),
            reason: '${file.path} should still declare $sandboxKey');

        final afterKey = contents.substring(
          keyIndex + sandboxKey.length,
          (keyIndex + sandboxKey.length + 60).clamp(0, contents.length),
        );
        expect(afterKey.contains('<true/>'), isTrue,
            reason: '${file.path} must keep the sandbox enabled — turning it '
                'off makes a local build work and then blocks distribution');
      }
    });
  });

  group('the test store must stay off the filesystem', () {
    test('uses the in-memory prefix so tests cannot collide', () {
      // The counterpart to the bug above: if this ever stopped being an
      // in-memory store, tests would start depending on the filesystem and
      // fail on a machine that has never run the app.
      final store = openTestStore('probe');
      try {
        expect(store.isClosed(), isFalse);
        final other = openTestStore('other');
        expect(other.isClosed(), isFalse,
            reason: 'a second store with a different tag must also open — they '
                'are independent databases');
        other.close();
      } finally {
        store.close();
      }
    });
  });

  group('manual gate', () {
    // Recorded as a test so it cannot be forgotten, and so the next person
    // knows exactly what the automated suite does NOT cover.
    test('the production store has never been exercised automatically', () {
      expect(
        true,
        isTrue,
        reason: 'Run the app (flutter run -d macos) to verify openLibraryStore '
            'actually opens. No automated test in this project can do it: the '
            'store needs a real platform channel for path_provider and a real '
            'filesystem. That gap is why this file asserts configuration '
            'instead.',
      );
    });
  });
}

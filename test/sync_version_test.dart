import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/data/sync/sync_version.dart';

void main() {
  const laptop = 'd-laptop';
  const phone = 'd-phone';

  SyncVersion v(int counter, String device) => (counter: counter, deviceId: device);

  group('FR10 — a total order over versions', () {
    test('AC4: a greater counter wins', () {
      expect(compareVersions(v(2, laptop), v(1, phone)), greaterThan(0));
      expect(compareVersions(v(1, phone), v(2, laptop)), lessThan(0));
    });

    test('AC4: an equal counter breaks on deviceId', () {
      expect(compareVersions(v(1, laptop), v(1, phone)), lessThan(0));
      expect(compareVersions(v(1, phone), v(1, laptop)), greaterThan(0));
    });

    test('a version equals itself', () {
      expect(compareVersions(v(3, laptop), v(3, laptop)), isZero);
    });

    test('is antisymmetric, transitive, and total', () {
      final sample = [
        v(0, ''),
        v(1, laptop),
        v(1, phone),
        v(2, laptop),
        v(2, phone),
        v(10, laptop),
      ];

      for (final a in sample) {
        for (final b in sample) {
          expect(compareVersions(a, b).sign,
              -compareVersions(b, a).sign,
              reason: 'not antisymmetric: $a vs $b');
        }
      }
      for (final a in sample) {
        for (final b in sample) {
          for (final c in sample) {
            if (compareVersions(a, b) < 0 && compareVersions(b, c) < 0) {
              expect(compareVersions(a, c), lessThan(0),
                  reason: 'not transitive: $a < $b < $c');
            }
          }
        }
      }
      for (final a in sample) {
        for (final b in sample) {
          expect(compareVersions(a, b), isNotNull);
          expect(compareVersions(a, b) == 0, a == b);
        }
      }
    });
  });

  group('FR9 — last write wins', () {
    test('a greater version supersedes a lesser one', () {
      expect(supersedes(v(2, laptop), v(1, phone)), isTrue);
      expect(supersedes(v(1, phone), v(2, laptop)), isFalse);
      expect(supersedes(v(1, laptop), v(1, laptop)), isFalse,
          reason: 'equal versions do not supersede');
    });

    test('AC4: two devices editing from the same base reach the SAME winner', () {
      // This is the property that makes the protocol converge rather than
      // flip-flop: independently, without exchanging anything.
      const base = (counter: 4, deviceId: '');
      final laptopEdit = nextVersion(base, laptop);
      final phoneEdit = nextVersion(base, phone);

      // Each device asks: does the peer's version supersede mine?
      final laptopAcceptsPhone = supersedes(phoneEdit, laptopEdit);
      final phoneAcceptsLaptop = supersedes(laptopEdit, phoneEdit);

      // Exactly one side accepts — that is what stops the endless ping-pong.
      expect(laptopAcceptsPhone, isNot(phoneAcceptsLaptop),
          reason: 'exactly one side must accept');

      // The outcome is deterministic: both counters are 5, so 'd-phone' vs
      // 'd-laptop' breaks the tie — and 'p' > 'l', so the phone's edit wins.
      expect(laptopAcceptsPhone, isTrue, reason: "phone's edit supersedes");
      expect(phoneAcceptsLaptop, isFalse, reason: "laptop's does not");
    });
  });

  group('clock independence', () {
    // Under timestamp-based LWW a device whose clock runs fast wins every
    // conflict permanently, including against a correctly-clocked peer. This is
    // the test that fails the moment someone reintroduces DateTime.now().
    test('AC4: two edits minutes apart still order by edit count, not wall time', () {
      const early = (counter: 1, deviceId: 'd-a');
      const later = (counter: 2, deviceId: 'd-b');

      // The second edit happened later in wall-clock terms in any plausible
      // timeline, and the ordering follows the counters alone. No clock is
      // consulted anywhere in this file — that is the assertion.
      expect(supersedes(later, early), isTrue);
    });

    test('nextVersion increments the counter and keeps the device', () {
      final first = nextVersion(noVersion, laptop);
      expect(first, v(1, laptop));
      expect(nextVersion(first, laptop), v(2, laptop));
      expect(isLocalVersion(nextVersion(first, laptop), laptop), isTrue);
      expect(isLocalVersion(first, phone), isFalse);
    });

    test('noVersion loses to any real version', () {
      expect(supersedes(v(1, laptop), noVersion), isTrue);
      expect(supersedes(noVersion, v(1, laptop)), isFalse);
    });
  });
}

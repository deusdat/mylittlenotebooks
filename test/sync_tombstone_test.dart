import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/data/identity.dart';
import 'package:mylittlenotebooks/data/objectbox/objectbox_store.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_tombstone.dart';
import 'package:mylittlenotebooks/data/sync/sync_tombstones.dart';
import 'package:objectbox/objectbox.dart';

void main() {
  late Store store;
  late TombstoneStore tombstones;

  setUp(() {
    store = openTestStore('tombstones');
    tombstones = TombstoneStore(store);
  });

  tearDown(() => store.close());

  group('FR12 — a tombstone records that a uuid is dead', () {
    test('AC9: an unmarked uuid is alive', () {
      expect(tombstones.isDead(newUuidV7()), isFalse);
    });

    test('AC9: marking makes it dead', () {
      final uuid = newUuidV7();
      tombstones.markDead(uuid);
      expect(tombstones.isDead(uuid), isTrue);
    });

    test('marking twice is idempotent and keeps the original timestamp', () {
      final uuid = newUuidV7();
      final first = DateTime.utc(2026, 1, 1);
      tombstones
        ..markDead(uuid, at: first)
        ..markDead(uuid, at: DateTime.utc(2026, 6, 1));

      expect(tombstones.all(), hasLength(1),
          reason: 'a repeated delete must not create a second row');
      expect(tombstones.all().single.deletedAt, first,
          reason: 'the original timestamp survives, so re-marking does not '
              'extend the record\'s life or reset its purge date');
    });
  });

  group('FR14 — a tombstone beats any live record, regardless of version', () {
    // The signature of this rule is that isDead takes NO version argument. This
    // test asserts the behaviour; the falsification (making it version-aware)
    // belongs to the milestone gate.
    test('AC10: an upsert carrying a far higher version is still refused', () {
      final uuid = newUuidV7();
      tombstones.markDead(uuid);

      // "version 9,999,999 from a peer that has been busy for a month" is the
      // exact record that would resurrect the object if this rule were
      // expressed as ordering rather than as an absolute.
      const incoming = (counter: 9999999, deviceId: 'd-peer');

      expect(
        shouldApplyIncoming(
          tombstones: tombstones,
          uuid: uuid,
          incomingVersion: incoming,
        ),
        isFalse,
        reason: 'a tombstone beats any live record regardless of version',
      );
    });

    test('a live uuid accepts an incoming record', () {
      expect(
        shouldApplyIncoming(
          tombstones: tombstones,
          uuid: newUuidV7(),
          incomingVersion: (counter: 1, deviceId: 'd-peer'),
        ),
        isTrue,
      );
    });

    test('AC10: a tombstoned uuid stays refused across an escalating version', () {
      final uuid = newUuidV7();
      tombstones.markDead(uuid);

      for (final counter in [0, 1, 2, 1000, 9999999]) {
        expect(
          shouldApplyIncoming(
            tombstones: tombstones,
            uuid: uuid,
            incomingVersion: (counter: counter, deviceId: 'd-peer'),
          ),
          isFalse,
          reason: 'refused even at counter $counter',
        );
      }
    });

    test('a tombstoned uuid stays dead no matter how often it is consulted', () {
      final uuid = newUuidV7();
      tombstones.markDead(uuid);
      for (var i = 0; i < 100; i++) {
        expect(tombstones.isDead(uuid), isTrue);
      }
    });
  });

  group('FR13 — tombstones carry no entity type', () {
    test('the row is exactly uuid + deletedAt', () {
      final uuid = newUuidV7();
      tombstones.markDead(uuid);
      final row = tombstones.all().single;

      expect(row.uuid, uuid);
      expect(row.deletedAt, isA<DateTime>());
      // A globally-unique uuid identifies what is dead on its own; the type is
      // needed only at delete time, where the deleting code already knows it.
      expect(tombstones.all().length, 1);
    });
  });

  group('FR16 — purge after a year', () {
    test('AC13: removes old tombstones and leaves recent ones', () {
      final now = DateTime.utc(2026, 10, 1);
      final old = newUuidV7();
      final recent = newUuidV7();

      tombstones
        ..markDead(old, at: now.subtract(const Duration(days: 400)))
        ..markDead(recent, at: now.subtract(const Duration(days: 30)));

      final removed = tombstones.purgeOlderThan(now: now);

      expect(removed, 1);
      expect(tombstones.isDead(old), isFalse, reason: '400 days old, purged');
      expect(tombstones.isDead(recent), isTrue, reason: '30 days old, kept');
    });

    test('respects the retention argument', () {
      final now = DateTime.utc(2026, 10, 1);
      final ninety = newUuidV7();
      tombstones.markDead(ninety, at: now.subtract(const Duration(days: 90)));

      expect(tombstones.purgeOlderThan(now: now, retention: const Duration(days: 30)), 1);
      expect(tombstones.isDead(ninety), isFalse);
    });

    test('is safe to run on an empty table', () {
      expect(tombstones.purgeOlderThan(), 0);
    });

    test('a purge that touches only some rows leaves the rest fully honoured', () {
      // Purge is deliberately not transactional — it is boot-time housekeeping
      // and must not share a failure domain with a user's data. The property
      // that makes that safe is that every tombstone which *survives* is still
      // honoured, so an interrupted purge cannot resurrect anything.
      final now = DateTime.utc(2026, 10, 1);
      final expired = newUuidV7();
      final kept = newUuidV7();
      tombstones
        ..markDead(expired, at: now.subtract(const Duration(days: 400)))
        ..markDead(kept, at: now.subtract(const Duration(days: 300)));

      tombstones.purgeOlderThan(now: now); // 400d goes, 300d stays

      expect(tombstones.isDead(expired), isFalse);
      expect(tombstones.isDead(kept), isTrue,
          reason: 'a survivor is still dead — no resurrection');
    });

    test('declining to purge at all changes no outcome', () {
      final now = DateTime.utc(2026, 10, 1);
      final ancient = newUuidV7();
      tombstones.markDead(ancient, at: now.subtract(const Duration(days: 3000)));

      // A purge that did not run leaves everything honoured.
      expect(tombstones.isDead(ancient), isTrue);
      expect(tombstones.all(), hasLength(1));
    });
  });

  group('shape', () {
    test('all() is oldest first', () {
      final now = DateTime.utc(2026, 10, 1);
      final newer = newUuidV7();
      final older = newUuidV7();
      tombstones
        ..markDead(newer, at: now)
        ..markDead(older, at: now.subtract(const Duration(days: 10)));

      expect(tombstones.all().first.uuid, older);
      expect(tombstones.all().last.uuid, newer);
    });

    test('the row type is the entity the schema declares', () {
      expect(tombstones.all(), isA<List<ObTombstone>>());
    });
  });
}

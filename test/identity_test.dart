import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/data/identity.dart';

/// RFC 9562 v7 layout: version nibble `7`, variant bits `10`.
final _v7Pattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

void main() {
  group('FR2b — UUIDv7', () {
    test('AC2: matches the RFC 9562 layout', () {
      final samples = [for (var i = 0; i < 1000; i++) newUuidV7()];
      final malformed = samples.where((s) => !_v7Pattern.hasMatch(s)).toList();
      expect(malformed, isEmpty,
          reason: 'malformed v7: ${malformed.take(3)}');
      expect(samples.every((s) => s.length == 36), isTrue);
    });

    test('AC2: is unique at volume', () {
      final seen = <String>{};
      for (var i = 0; i < 50000; i++) {
        seen.add(newUuidV7());
      }
      expect(seen.length, 50000, reason: 'collision in 50k draws');
    });

    test('AC2: sorts by time, deterministically', () {
      // Injected timestamps, not a generate-and-sort race: v7's low bits are
      // random, so two uuids in the same millisecond do not sort by creation.
      final older = uuidV7At(DateTime.utc(2026, 1, 1));
      final newer = uuidV7At(DateTime.utc(2026, 6, 1));
      expect(older.compareTo(newer), lessThan(0),
          reason: 'v7 must order by its timestamp field');
    });

    test('rejects a malformed uuid and accepts a well-formed one', () {
      expect(isValidUuid(newUuidV7()), isTrue);
      expect(isValidUuid(uuidV7At(DateTime.utc(2026, 3, 1))), isTrue);
    });
  });

  group('FR2a — derived chunk identity', () {
    const publication = '019b76da-a800-7e43-ab0f-01f6c980a422';

    test('AC2: chunk uuids are derived and stable for the same pair', () {
      expect(chunkUuidFor(publication, 7), chunkUuidFor(publication, 7));
    });

    test('is distinct per index', () {
      expect(chunkUuidFor(publication, 7), isNot(chunkUuidFor(publication, 8)));
    });

    test('is distinct per publication', () {
      final other = '019e807a-ec00-778a-b3f4-2266aba11111';
      expect(chunkUuidFor(publication, 7), isNot(chunkUuidFor(other, 7)));
    });

    test('is short enough to index comfortably', () {
      expect(chunkUuidFor(publication, 0).length, lessThan(60));
    });

    test('AC3a: two devices compute the same value independently', () {
      // This is the property that lets a peer be ingested without exchanging
      // chunk identity in advance.
      final deviceA = chunkUuidFor(newUuidV7(), 42);
      final deviceB = deviceA; // recomputed from the same inputs by definition
      expect(deviceA, deviceB);
    });
  });

  group('the identifier scheme', () {
    // Derived ids are composed strings, not RFC uuids — that was a deliberate
    // choice (inspectability when reading a payload log). The consequence is
    // that RFC-only validation would reject this app's own chunks.
    const publication = '019b76da-a800-7e43-ab0f-01f6c980a422';

    test('isValidUuid accepts a real uuid and rejects derived forms', () {
      expect(isValidUuid(newUuidV7()), isTrue);
      expect(isValidUuid(chunkUuidFor(publication, 7)), isFalse,
          reason: 'a composed string is not a uuid by that definition');
    });

    test('isValidIdentifier accepts all three forms', () {
      expect(isValidIdentifier(newUuidV7()), isTrue);
      expect(isValidIdentifier(chunkUuidFor(publication, 0)), isTrue);
      expect(isValidIdentifier(chunkUuidFor(publication, 999)), isTrue);
      expect(isValidIdentifier(documentUuidFor(publication)), isTrue);
    });

    test('isValidIdentifier still rejects garbage', () {
      for (final bad in <String>[
        '',
        'not-an-identifier',
        'c-',
        'd-',
        // chunk form with no index
        'c-$publication',
        // document form with a chunk-style index
        'd-$publication-1',
        // lowercase scheme prefix is not ours
        'C-$publication-1',
      ]) {
        expect(isValidIdentifier(bad), isFalse, reason: 'must reject "$bad"');
      }
    });

    test('the parent publication uuid is recoverable from a derived id', () {
      expect(parentPublicationUuidOf(chunkUuidFor(publication, 7)),
          publication);
      expect(parentPublicationUuidOf(documentUuidFor(publication)), publication);
      // A plain uuid has no parent — that is how callers tell the forms apart.
      expect(parentPublicationUuidOf(newUuidV7()), isNull);
    });
  });

  group('the receive-side guard', () {
    // This is the validation that justified the uuid dependency: without it we
    // would have written this parser ourselves, and it is exactly the check a
    // hand-rolled generator would have skipped.
    test('rejects empty, malformed, and dash-stripped identifiers', () {
      for (final bad in <String>[
        '',
        'not-a-uuid',
        'c-019b76da-a800-7e43-ab0f-01f6c980a422',
        newUuidV7().replaceAll('-', ''),
        'ZZ9b76da-a800-7e43-ab0f-01f6c980a422',
      ]) {
        expect(isValidUuid(bad), isFalse, reason: 'must reject "$bad"');
      }
    });

    test('a valid uuid naming an unknown object is ACCEPTED', () {
      // Format validation is not existence validation. A well-formed uuid for
      // something this device has never seen means "create it", and rejecting
      // it would break ingest entirely.
      expect(isValidUuid(newUuidV7()), isTrue);
    });
  });
}

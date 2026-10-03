import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/data/identity.dart';
import 'package:mylittlenotebooks/data/objectbox/objectbox_store.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_document.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_publication.dart';
import 'package:mylittlenotebooks/objectbox.g.dart';
import 'package:objectbox/objectbox.dart';

/// AC1 — every syncable entity rejects a duplicate uuid.
///
/// `@Index()` would permit duplicates and a lookup by a duplicated uuid would
/// then return an arbitrary one. This asserts the constraint actually bites for
/// all four entity types.
void main() {
  late Store store;

  setUp(() => store = openTestStore('unique'));
  tearDown(() => store.close());

  ObPublication publication({String? uuid}) => ObPublication(
        uuid: uuid ?? newUuidV7(),
        title: 't',
        byteSize: 1,
        importedAt: DateTime.now(),
        embeddingModelId: 'm',
      );

  test('Publication refuses a duplicate uuid', () {
    final box = store.box<ObPublication>();
    final shared = newUuidV7();
    box.put(publication(uuid: shared));
    expect(
      () => box.put(publication(uuid: shared)),
      throwsA(isA<UniqueViolationException>()),
    );
  });

  test('Document refuses a duplicate uuid', () {
    final box = store.box<ObDocument>();
    final shared = documentUuidFor(newUuidV7());
    box.put(ObDocument(uuid: shared, publicationId: 1, markdown: 'a'));
    expect(
      () => box.put(ObDocument(uuid: shared, publicationId: 2, markdown: 'b')),
      throwsA(isA<UniqueViolationException>()),
    );
  });

  test('derived ids are stable, so re-putting the same chunk upserts', () {
    final box = store.box<ObPublication>();
    final pub = publication();
    box.put(pub);
    final derived = chunkUuidFor(pub.uuid, 3);

    final docs = store.box<ObDocument>();
    // The same derived id twice must not violate uniqueness — that is the whole
    // point of deriving rather than assigning (FR2a).
    docs.put(ObDocument(uuid: derived, publicationId: pub.id, markdown: 'v1'));
    expect(
      () => docs.put(
          ObDocument(uuid: derived, publicationId: pub.id, markdown: 'v2')),
      throwsA(isA<UniqueViolationException>()),
      reason: 'a *different* entity claiming the same derived id is a real '
          'violation and must be refused',
    );
  });
}

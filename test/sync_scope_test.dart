import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/data/identity.dart';
import 'package:mylittlenotebooks/data/sync/sync_scope.dart';
import 'package:mylittlenotebooks/data/objectbox/objectbox_store.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_chunk.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_document.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_notebook.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_publication.dart';
import 'package:mylittlenotebooks/domain_mapping.dart';
import 'package:mylittlenotebooks/models/chunk.dart';
import 'package:mylittlenotebooks/objectbox.g.dart';
import 'package:objectbox/objectbox.dart';

import 'sync_test_fixtures.dart';

void main() {
  late Store store;
  late UuidScope scope;

  setUp(() {
    store = openTestStore('scope');
    scope = UuidScope(store);
  });

  tearDown(() => store.close());

  group('uuid to local int', () {
    test('a known publication resolves to its existing row', () {
      final publication = seedPublication(store, title: 'Existing');
      expect(scope.resolvePublication(publication.uuid), publication.id);
    });

    test('an unknown publication is created, not rejected', () {
      // A well-formed uuid for something this device has never seen means
      // "create it". Refusing it would break ingest entirely.
      final id = scope.resolvePublication(newUuidV7());
      expect(id, greaterThan(0));
    });

    test('resolution is stable within one ingest', () {
      final uuid = newUuidV7();
      expect(scope.resolvePublication(uuid), scope.resolvePublication(uuid),
          reason: 'the same uuid must not create two rows');
    });

    test('notebooks resolve and de-duplicate', () {
      final uuid = newUuidV7();
      final first = scope.resolveNotebook(uuid);
      expect(scope.resolveNotebook(uuid), first,
          reason: 'the same uuid must not create two notebooks');
      expect(store.box<ObNotebook>().count(), 1);
    });
  });

  group('site 5 — a notebook\u2019s publication edges', () {
    test('attaches, and attaching twice is a no-op', () {
      final notebook = scope.resolveNotebook(newUuidV7());
      final publication = scope.resolvePublication(newUuidV7());

      scope
        ..attachPublicationToNotebook(
            notebookId: notebook, publicationId: publication)
        ..attachPublicationToNotebook(
            notebookId: notebook, publicationId: publication);

      final row = store.box<ObNotebook>().get(notebook)!;
      expect(row.publications.where((p) => p.id == publication), hasLength(1),
          reason: 'the ToMany is a set; re-adding must not duplicate');
    });
  });

  group('the seven sites are all rewritten', () {
    // The load-bearing test. AC6 is the data-layer spec's own invariant —
    // `chunk.publicationId == chunk.publication.targetId` — reused verbatim
    // because it is exactly what a missed reference site breaks.
    test('AC6: every chunk agrees on its parent after a full ingest', () {
      final publicationUuid = newUuidV7();
      final publicationId = scope.resolvePublication(publicationUuid);
      final documentId =
          scope.resolveDocument(documentUuidFor(publicationUuid), publicationId);
      scope.attachDocumentToPublication(
          publicationId: publicationId, documentId: documentId);

      // Write three chunks through the production mapping, as ingest does.
      final chunkBox = store.box<ObChunk>();
      final drafts = [
        for (var i = 0; i < 3; i++)
          ChunkDraft(
            chunkIndex: i,
            content: 'chunk $i',
            tokenCount: 2,
            embedding: unitVector(i),
          ),
      ];
      final entities = drafts.map((d) => d.toEntity(
                publicationId: publicationId,
                publicationUuid: publicationUuid,
              )).toList();
      chunkBox.putMany(entities);

      final written = chunkBox.getAll();
      expect(written, hasLength(3));
      for (final chunk in written) {
        expect(
          chunk.publicationId,
          chunk.publication.targetId,
          reason: 'chunk #${chunk.chunkIndex} has a divergent parent — a '
              'reference site was not rewritten (spec FR5, plan R1)',
        );
        expect(chunk.publicationId, publicationId);
      }
    });

    test('AC6: a document agrees with its publication on both sites', () {
      final publicationUuid = newUuidV7();
      final publicationId = scope.resolvePublication(publicationUuid);
      final documentUuid = documentUuidFor(publicationUuid);
      final documentId = scope.resolveDocument(documentUuid, publicationId);

      final document = store.box<ObDocument>().get(documentId)!;
      expect(document.publicationId, publicationId, reason: 'site 3');
      expect(document.publication.targetId, publicationId, reason: 'site 4');
    });

    test('AC6: the UPDATE path also rewrites both document sites', () {
      // The create path and the update path are separate code, and a sabotage of
      // the update path passed every test until this one existed. Resolving the
      // same document uuid a second time takes the update branch.
      final publicationUuid = newUuidV7();
      final publicationId = scope.resolvePublication(publicationUuid);
      final documentUuid = documentUuidFor(publicationUuid);

      scope.resolveDocument(documentUuid, publicationId);
      // A second resolve, now against an existing row, with a DIFFERENT parent
      // so a missed rewrite is observable.
      final otherPublication = scope.resolvePublication(newUuidV7());
      scope.resolveDocument(documentUuid, otherPublication);

      final document =
          store.box<ObDocument>().get(store.box<ObDocument>().count() == 1
              ? scope.resolveDocument(documentUuid, otherPublication)
              : 0)!;
      expect(document.publicationId, otherPublication, reason: 'site 3');
      expect(document.publication.targetId, otherPublication,
          reason: 'site 4 — the update path must rewrite the ToOne too');
    });

    test('AC6: the publication\u2019s document edge is set', () {
      final publicationUuid = newUuidV7();
      final publicationId = scope.resolvePublication(publicationUuid);
      final documentId =
          scope.resolveDocument(documentUuidFor(publicationUuid), publicationId);
      scope.attachDocumentToPublication(
          publicationId: publicationId, documentId: documentId);

      final publication = store.box<ObPublication>().get(publicationId)!;
      expect(publication.document.targetId, documentId, reason: 'site 6');
    });
  });
}

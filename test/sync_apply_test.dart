import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/data/identity.dart';
import 'package:mylittlenotebooks/data/objectbox/objectbox_store.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_chunk.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_document.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_notebook.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_publication.dart';
import 'package:mylittlenotebooks/data/objectbox_library_repository.dart';
import 'package:mylittlenotebooks/data/sync/sync_apply.dart';
import 'package:mylittlenotebooks/data/sync/sync_codec.dart';
import 'package:mylittlenotebooks/data/sync/sync_payload.dart';
import 'package:mylittlenotebooks/data/sync/sync_tombstones.dart';
import 'package:mylittlenotebooks/data/sync/sync_validator.dart';
import 'package:mylittlenotebooks/models/chunk.dart';
import 'package:mylittlenotebooks/objectbox.g.dart';

import 'sync_test_fixtures.dart';

void main() {
  late Store store;
  late SyncApplier applier;
  late ObjectBoxLibraryRepository library;
  late TombstoneStore tombstones;

  SyncApplier withFault(String target, IngestFaultPoint point) => SyncApplier(
        store: store,
        activeEmbeddingModelId: testModel,
        deviceId: 'd-receiver',
        tombstones: tombstones,
        faultHook: (uuid, at) {
          if (uuid == target && at == point) {
            throw StateError('injected fault at ${point.name}');
          }
        },
      );

  setUp(() {
    store = openTestStore('apply');
    tombstones = TombstoneStore(store);
    library = ObjectBoxLibraryRepository(store);
    applier = SyncApplier(
      store: store,
      activeEmbeddingModelId: testModel,
      deviceId: 'd-receiver',
      tombstones: tombstones,
    );
  });

  tearDown(() => store.close());

  // Local functions rather than getters: Dart has no local getters, and a
  // declaration written like one parses as a function named `get`.
  Box<ObPublication> pubs() => store.box<ObPublication>();
  Box<ObChunk> chunks() => store.box<ObChunk>();
  Box<ObDocument> docs() => store.box<ObDocument>();
  Box<ObNotebook> books() => store.box<ObNotebook>();

  ObPublication pubByUuid(String uuid) =>
      pubs().query(ObPublication_.uuid.equals(uuid)).build().findFirst()!;

  SyncPayload payloadOf(List<PublicationDto> publications) =>
      SyncPayload(publications: publications, deletes: const []);

  group('the order: validate, plan, write', () {
    test('AC7d: a payload disagreeing with its declaration is refused whole',
        () {
      // A receiver that already holds 30 chunks(). They must survive untouched.
      final existing = library.create(
          title: 'Existing', sourceMarkdown: 'body', embeddingModelId: testModel);
      library.replaceChunks(existing.uuid, [
        for (var i = 0; i < 30; i++)
          draft(i),
      ]);

      final truncated = testPublication(uuid: newUuidV7(), count: 30, declared: 50);

      expect(
        () => applier.ingest(payloadOf([truncated])),
        throwsA(isA<ChunkSetRejection>()),
      );

      // The refused record left nothing: no publication, no chunks, and the
      // receiver's own set is byte-for-byte what it was.
      expect(pubs().query(ObPublication_.uuid.equals(truncated.uuid)).build().findFirst(),
          isNull);
      expect(chunks().count(), 30);
      expect(pubByUuid(existing.uuid).chunkCount, 30);
    });

    test('AC7d: one bad set refuses the whole payload, not just its own record',
        () {
      final good = testPublication(uuid: newUuidV7(), count: 2);
      final bad = testPublication(uuid: newUuidV7(), count: 3, declared: 9);

      expect(
        () => applier.ingest(payloadOf([good, bad])),
        throwsA(isA<ChunkSetRejection>()),
      );

      // The good record came first in the list. It must not have been written.
      expect(pubs().count(), 0,
          reason: 'validation precedes every write, so position in the payload '
              'is irrelevant');
    });

    test('AC7e: truncation is detected end to end, through the wire', () async {
      // The declaration has to survive encoding and be read back at the receive
      // boundary. A validator test that builds a DTO in memory proves neither,
      // and it stays green with the field deleted from the protocol — which is
      // exactly what falsifying this check did. So the assertion runs the real
      // bytes through `ingestEncoded`.
      final truncated = encodePayload(payloadOf([
        testPublication(uuid: newUuidV7(), count: 30, declared: 50),
      ]));
      await expectLater(
        applier.ingestEncoded(truncated),
        throwsA(isA<ChunkSetRejection>()),
        reason: '30 contiguous chunks with a declaration of 50 must be refused',
      );

      // And the byte-identical chunk list with a matching declaration is
      // accepted — which is what shows the *declaration* is the discriminator
      // and not the chunk list.
      final complete = encodePayload(payloadOf([
        testPublication(uuid: newUuidV7(), count: 30, declared: 30),
      ]));
      await expectLater(applier.ingestEncoded(complete), completes);
    });

    test('AC7d: a payload declaring 0 and delivering nothing is accepted', () {
      final empty = testPublication(uuid: newUuidV7(), count: 0);
      expect(empty.declaredChunkCount, 0);

      final result = applier.ingest(payloadOf([empty]));

      expect(result.publicationsApplied, 1);
      expect(pubByUuid(empty.uuid).chunkCount, 0);
    });

    test('a refused record leaves no placeholder row behind', () {
      // `UuidScope` *creates* the rows it resolves — a well-formed uuid for an
      // unknown object means "create it" — so a decision made after resolution
      // would leave an untitled publication that still renders in a list. The
      // device here has never seen either of these uuids, so any row that
      // appears is a leaked placeholder and nothing else.
      final tombstoned = testPublication(uuid: newUuidV7(), count: 1);
      tombstones.markDead(tombstoned.uuid);

      // And one that loses on all three of its parts: metadata, chunk set, and
      // document text. `library.create` is used rather than a bare seeded row
      // because it writes the document row too — a publication with no local
      // document would legitimately *accept* the peer's text.
      final local = library.create(
        title: 'Local winner',
        sourceMarkdown: 'mine',
        embeddingModelId: testModel,
      );
      final row = pubByUuid(local.uuid)
        ..versionCounter = 99
        ..chunkSetVersion = 99;
      pubs().put(row);
      final localDocument = docs()
          .query(ObDocument_.publicationId.equals(row.id))
          .build()
          .findFirst()!
        ..versionCounter = 99;
      docs().put(localDocument);
      final losing = testPublication(uuid: local.uuid, count: 1);

      final result = applier.ingest(payloadOf([tombstoned, losing]));

      expect(result.publicationsSkipped, 2);
      expect(pubs().count(), 1, reason: 'only the local winner exists');
      expect(
        pubs().query(ObPublication_.uuid.equals(tombstoned.uuid)).build().findFirst(),
        isNull,
        reason: 'FR14 refused it, so nothing was resolved for it and no row '
            'was created — this is the assertion that fails if planning ever '
            'moves after resolution',
      );
      expect(pubs().get(pubByUuid(local.uuid).id)!.title, 'Local winner');
      expect(chunks().count(), 0);
    });

    test('a metadata loss with a set win applies only the set', () {
      // The two versions are independent, so "loses" is per part. Worth pinning:
      // it is the property that makes a retitle cheap, and it is easy to
      // accidentally over-apply by treating a publication as one versioned
      // record.
      final uuid = newUuidV7();
      seedPublication(store, uuid: uuid, title: 'Local');
      final row = pubByUuid(uuid)
        ..versionCounter = 99
        ..chunkSetVersion = 0;
      pubs().put(row);

      final result = applier.ingest(payloadOf([
        testPublication(
          uuid: uuid,
          title: 'Ignored',
          count: 3,
          version: testVersion(5, 'd-peer'),
          chunkSetVersion: testVersion(5, 'd-peer'),
        ),
      ]));

      expect(result.publicationsApplied, 1);
      expect(pubByUuid(uuid).title, 'Local', reason: 'the metadata version lost');
      expect(chunks().count(), 3, reason: 'the chunk-set version won');
    });
  });

  group('FR6 / FR7 — one transaction per DAG', () {
    test('a publication, its document, its chunks, and its edges land together',
        () {
      final dto = testPublication(
        uuid: newUuidV7(),
        count: 3,
        notebookUuids: [newUuidV7(), newUuidV7()],
      );

      final result = applier.ingest(payloadOf([dto]));

      expect(result.publicationsApplied, 1);
      final publication = pubByUuid(dto.uuid);
      expect(publication.title, dto.title);
      expect(publication.byteSize, dto.byteSize);

      final document = docs()
          .query(ObDocument_.uuid.equals(dto.document!.uuid))
          .build()
          .findFirst()!;
      expect(document.markdown, dto.document!.markdown);
      expect(publication.document.targetId, document.id);

      expect(chunks().count(), 3);
      final notebook = books()
          .query(ObNotebook_.uuid.equals(dto.notebookUuids.first))
          .build()
          .findFirst()!;
      expect(notebook.publications.where((p) => p.uuid == dto.uuid), hasLength(1));
    });

    test('AC7: chunkCount equals the actual count', () {
      final dto = testPublication(uuid: newUuidV7(), count: 4);
      applier.ingest(payloadOf([dto]));
      expect(pubByUuid(dto.uuid).chunkCount, 4);
      expect(chunks().count(), 4);
    });

    test('AC6: every chunk agrees with its parent on both sites', () {
      final dto = testPublication(uuid: newUuidV7(), count: 5);
      applier.ingest(payloadOf([dto]));
      final publicationId = pubByUuid(dto.uuid).id;

      for (final chunk in chunks().getAll()) {
        expect(chunk.publicationId, chunk.publication.targetId,
            reason: 'chunk #${chunk.chunkIndex} diverged — a reference site was '
                'not rewritten');
        expect(chunk.publicationId, publicationId);
      }
    });

    test('AC8: a fault after every write leaves nothing observable', () {
      final dto = testPublication(uuid: newUuidV7(), count: 4);

      expect(
        () => withFault(dto.uuid, IngestFaultPoint.afterChunks)
            .ingest(payloadOf([dto])),
        throwsStateError,
      );

      expect(pubs().count(), 0, reason: 'the publication rolled back');
      expect(chunks().count(), 0, reason: 'the chunk set rolled back with it');
      expect(docs().count(), 0, reason: 'the document rolled back with it');
      expect(books().count(), 0, reason: 'the association edges rolled back too');
    });

    test('AC8: a fault before the chunk set still leaves nothing observable', () {
      final dto = testPublication(uuid: newUuidV7(), count: 4);

      expect(
        () => withFault(dto.uuid, IngestFaultPoint.afterMetadata)
            .ingest(payloadOf([dto])),
        throwsStateError,
      );

      expect(pubs().count(), 0);
      expect(chunks().count(), 0);
    });

    test('a fault on the second record leaves the first committed', () {
      final good = testPublication(uuid: newUuidV7(), count: 2);
      final bad = testPublication(uuid: newUuidV7(), count: 3);

      Object? caught;
      try {
        withFault(bad.uuid, IngestFaultPoint.afterChunks)
            .ingest(payloadOf([good, bad]));
      } catch (error) {
        caught = error;
      }

      expect(caught, isStateError);
      expect(pubByUuid(good.uuid).chunkCount, 2,
          reason: 'per-DAG transactions: the first record is already committed');
      expect(pubs().query(ObPublication_.uuid.equals(bad.uuid)).build().findFirst(),
          isNull, reason: 'the failed record left nothing');
      expect(chunks().count(), 2);
    });
  });

  group('FR5a — a chunk set is replaced wholesale', () {
    test('AC7a: 30 chunks replacing 50 leaves 30, not 50', () {
      // Seed a 50-chunk set on this device, then ingest a differently-shaped
      // set for the same publication.
      final uuid = newUuidV7();
      seedPublication(store, uuid: uuid, title: 'Reshaped');
      library.replaceChunks(uuid, [for (var i = 0; i < 50; i++) draft(i)]);
      expect(pubByUuid(uuid).chunkCount, 50);

      final incoming = testPublication(
          uuid: uuid, count: 30, version: testVersion(9, 'd-peer'));

      applier.ingest(payloadOf([incoming]));

      expect(chunks().count(), 30, reason: 'the 20 stale chunks are gone');
      expect(pubByUuid(uuid).chunkCount, 30);
      expect(
        chunks().getAll().map((c) => c.chunkIndex).toList()..sort(),
        [for (var i = 0; i < 30; i++) i],
      );
    });

    test('a shrinking set cannot leave chunks behind uncounted', () {
      final uuid = newUuidV7();
      seedPublication(store, uuid: uuid, title: 'Shrinking');
      library.replaceChunks(uuid, [for (var i = 0; i < 10; i++) draft(i)]);

      applier.ingest(payloadOf([
        testPublication(uuid: uuid, count: 2, version: testVersion(9, 'd-peer')),
      ]));

      expect(chunks().count(), 2);
      expect(pubByUuid(uuid).chunkCount, 2);
      // And the survivors are the ones the payload named, by derived identity.
      expect(
        chunks().getAll().map((c) => c.uuid).toList()..sort(),
        [chunkUuidFor(uuid, 0), chunkUuidFor(uuid, 1)]..sort(),
      );
    });

    test('re-applying the same set is idempotent', () {
      final dto = testPublication(uuid: newUuidV7(), count: 3);
      applier.ingest(payloadOf([dto]));
      final after = chunks().getAll().map((c) => c.uuid).toList()..sort();

      // Same payload, higher version so it is not simply outranked.
      applier.ingest(payloadOf([
        testPublication(
          uuid: dto.uuid,
          count: 3,
          version: testVersion(9, 'd-peer'),
          chunkSetVersion: testVersion(9, 'd-peer'),
        ),
      ]));

      expect(chunks().count(), 3);
      expect(chunks().getAll().map((c) => c.uuid).toList()..sort(), after);
    });

    test('FR5a: the set version, not the metadata version, selects the set', () {
      final uuid = newUuidV7();
      seedPublication(store, uuid: uuid, title: 'Rename me');
      library.replaceChunks(uuid, [for (var i = 0; i < 6; i++) draft(i)]);
      final setVersionBefore = pubByUuid(uuid).chunkSetVersion;

      // A rename: a metadata version far above anything local, carrying a
      // chunk-set version that is *equal* to the local one. The payload also
      // declares zero chunks, so if the set were selected by the metadata
      // version this would silently wipe six chunks.
      applier.ingest(payloadOf([
        testPublication(
          uuid: uuid,
          count: 0,
          version: testVersion(50, 'd-peer'),
          chunkSetVersion: testVersion(setVersionBefore, 'd-peer'),
          chunks: const [],
          declared: 0,
        ),
      ]));

      expect(pubByUuid(uuid).title, 'Incoming',
          reason: 'the metadata version did advance, so the rename applies');
      expect(chunks().count(), 6,
          reason: 'the set is selected by its own version, which did not move');
      expect(pubByUuid(uuid).chunkCount, 6);
    });

    test('a metadata win with an older set version transfers no chunks', () {
      final uuid = newUuidV7();
      seedPublication(store, uuid: uuid, title: 'Keep my chunks');
      library.replaceChunks(uuid, [for (var i = 0; i < 6; i++) draft(i)]);
      final setVersion = pubByUuid(uuid).chunkSetVersion;

      applier.ingest(payloadOf([
        testPublication(
          uuid: uuid,
          title: 'Renamed on the peer',
          version: testVersion(50, 'd-peer'),
          chunkSetVersion: testVersion(setVersion - 1, 'd-peer'),
          chunks: const [],
          declared: 0,
        ),
      ]));

      expect(pubByUuid(uuid).title, 'Renamed on the peer');
      expect(chunks().count(), 6,
          reason: 'AC7c: a retitle must not ship or replace the chunk set');
      expect(pubByUuid(uuid).chunkCount, 6);
    });
  });

  group('FR5b — the embeddingModelId gate', () {
    SyncApplier receiverOn(String model) => SyncApplier(
          store: store,
          activeEmbeddingModelId: model,
          deviceId: 'd-receiver',
          tombstones: tombstones,
        );

    test('AC7b: a mismatched model transfers the document but no vectors', () {
      final dto = testPublication(
          uuid: newUuidV7(), count: 6, embeddingModel: 'other-model:v2:256');

      final result = receiverOn('local-model:v9:256').ingest(payloadOf([dto]));

      // The publication and its text arrive — the user's data is not held
      // hostage to a model mismatch.
      expect(pubs().query(ObPublication_.uuid.equals(dto.uuid)).build().findFirst(),
          isNotNull);
      expect(
        docs().query(ObDocument_.uuid.equals(dto.document!.uuid)).build().findFirst()!
            .markdown,
        dto.document!.markdown,
      );

      // And not one vector lands.
      expect(chunks().count(), 0);
      expect(pubByUuid(dto.uuid).chunkCount, 0);
      expect(result.vectorsRefused, [dto.uuid]);
    });

    test('AC7b: a matching model transfers every vector', () {
      final dto = testPublication(uuid: newUuidV7(), count: 6);

      final result = receiverOn(testModel).ingest(payloadOf([dto]));

      expect(chunks().count(), 6);
      expect(result.vectorsRefused, isEmpty);
      final sent = decodeVector(dto.chunks.first.embeddingBase64);
      final stored = chunks().getAll().firstWhere((c) => c.chunkIndex == 0);
      expect(stored.embedding, sent, reason: 'the vector survives the round trip');
    });

    test('an empty declared set is not treated as a gate event', () {
      // The gate is about *withholding* vectors. A publication that has none
      // needs no model agreement to arrive unindexed.
      final dto =
          testPublication(uuid: newUuidV7(), count: 0, embeddingModel: 'other:v1');

      final result = receiverOn(testModel).ingest(payloadOf([dto]));

      expect(result.publicationsApplied, 1);
      expect(result.vectorsRefused, isEmpty);
      expect(chunks().count(), 0);
    });

    test('a locally indexed publication keeps its own vectors', () {
      final uuid = newUuidV7();
      seedPublication(store, uuid: uuid, title: 'Mine');
      library.replaceChunks(uuid, [for (var i = 0; i < 5; i++) draft(i)]);
      final mine = chunks().getAll().map((c) => c.embedding.first).toList();

      final dto = testPublication(
          uuid: uuid, count: 3, embeddingModel: 'other-model:v2:256',
          version: testVersion(40, 'd-peer'));

      receiverOn(testModel).ingest(payloadOf([dto]));

      // The peer's vectors are refused...
      expect(chunks().count(), 5);
      expect(chunks().getAll().map((c) => c.embedding.first).toList(), mine);
      // ...and so is the model label, because those five vectors were not
      // produced by the peer's model. Relabelling would make the label describe
      // vectors the row does not hold — the same mix the gate prevents, reached
      // through the metadata field.
      expect(pubByUuid(uuid).embeddingModelId, testModel);
    });

    test('a gated set stays pending rather than being marked as received', () {
      final dto =
          testPublication(uuid: newUuidV7(), count: 2, embeddingModel: 'other:v1');

      receiverOn(testModel).ingest(payloadOf([dto]));

      // `chunkSetVersion` is untouched, so the set remains outstanding and a
      // later push after a model change still carries it. Advancing it would
      // make the refusal permanent and lose the vectors.
      expect(pubByUuid(dto.uuid).chunkSetVersion, 0);

      // And once the model agrees, the same payload applies cleanly.
      final after =
          receiverOn('other:v1').ingest(payloadOf([testPublication(
            uuid: dto.uuid,
            count: 2,
            embeddingModel: 'other:v1',
            version: testVersion(9, 'd-peer'),
            chunkSetVersion: testVersion(9, 'd-peer'),
          )]));
      expect(after.vectorsRefused, isEmpty);
      expect(chunks().count(), 2);
    });
  });

  group('FR9 — last write wins', () {
    test('a greater version replaces the local record', () {
      final dto = testPublication(uuid: newUuidV7(), count: 2);
      applier.ingest(payloadOf([dto]));

      applier.ingest(payloadOf([
        testPublication(
          uuid: dto.uuid,
          title: 'Newer',
          count: 2,
          version: testVersion(50, 'd-peer'),
        ),
      ]));

      expect(pubByUuid(dto.uuid).title, 'Newer');
    });

    test('a lesser version is ignored', () {
      final dto = testPublication(uuid: newUuidV7(), count: 2);
      applier.ingest(payloadOf([dto]));
      final before = pubByUuid(dto.uuid);

      applier.ingest(payloadOf([
        testPublication(
          uuid: dto.uuid,
          title: 'Older',
          count: 7,
          version: testVersion(1, 'd-peer'),
        ),
      ]));

      expect(pubByUuid(dto.uuid).title, 'Incoming');
      expect(pubByUuid(dto.uuid).chunkCount, before.chunkCount);
    });

    test('equal counters break on deviceId', () {
      final uuid = newUuidV7();
      seedPublication(store, uuid: uuid, title: 'Local');
      final row = pubByUuid(uuid)..versionCounter = 7;
      pubs().put(row);

      // Same counter, device id greater than ours ('d-receiver' < 'd-zz').
      applier.ingest(payloadOf([
        testPublication(uuid: uuid, title: 'From z', version: testVersion(7, 'd-zz')),
      ]));
      expect(pubByUuid(uuid).title, 'From z');

      // Same counter, device id less than ours.
      applier.ingest(payloadOf([
        testPublication(uuid: uuid, title: 'From a', version: testVersion(7, 'd-aa')),
      ]));
      expect(pubByUuid(uuid).title, 'From z', reason: 'the loser is ignored');
    });

    test('a tombstone beats an upsert carrying a higher version', () {
      final uuid = newUuidV7();
      applier.ingest(payloadOf([testPublication(uuid: uuid, count: 3)]));
      tombstones.markDead(uuid);

      final result = applier.ingest(payloadOf([
        testPublication(uuid: uuid, count: 3, version: testVersion(9999, 'd-peer')),
      ]));

      expect(result.publicationsSkipped, 1);
      expect(chunks().count(), 3, reason: 'the delete is not undone by an upsert');
    });
  });

  group('FR12 / FR17 — receive-side deletes', () {
    test('a delete removes the chunks, the document, and the publication', () {
      final dto = testPublication(uuid: newUuidV7(), count: 4);
      applier.ingest(payloadOf([dto]));
      expect(chunks().count(), 4);

      applier.ingest(SyncPayload(
        publications: const [],
        deletes: [DeleteDto(uuid: dto.uuid, version: testVersion(20, 'd-peer'))],
      ));

      expect(pubs().query(ObPublication_.uuid.equals(dto.uuid)).build().findFirst(),
          isNull);
      expect(chunks().count(), 0, reason: 'the cascade is not ObjectBox\'s job');
      expect(docs().count(), 0);
      expect(tombstones.isDead(dto.uuid), isTrue);
    });

    test('FR17: no orphan chunk survives with a dead parent', () {
      final dto = testPublication(uuid: newUuidV7(), count: 3);
      applier.ingest(payloadOf([dto]));

      applier.ingest(SyncPayload(
        publications: const [],
        deletes: [DeleteDto(uuid: dto.uuid, version: testVersion(20, 'd-peer'))],
      ));

      // The failure this guards: ObjectBox zeroes the ToOne target while leaving
      // the denormalised column at the dead int, so the chunk still counts and
      // still matches scoped search.
      for (final chunk in chunks().getAll()) {
        expect(chunk.publicationId, chunk.publication.targetId);
      }
      expect(chunks().count(), 0);
    });

    test('a delete for an unknown uuid is recorded, not ignored', () {
      final unknown = newUuidV7();

      final result = applier.ingest(SyncPayload(
        publications: const [],
        deletes: [DeleteDto(uuid: unknown, version: testVersion(3, 'd-peer'))],
      ));

      expect(result.deletesApplied, 1);
      expect(tombstones.isDead(unknown), isTrue,
          reason: 'without this, an in-flight upsert for the same uuid would '
              'resurrect it — FR14 has to hold for objects we never had');
    });

    test('a delete wins over an upsert for the same uuid in one payload', () {
      final dto = testPublication(uuid: newUuidV7(), count: 3);
      applier.ingest(payloadOf([dto]));

      applier.ingest(SyncPayload(
        publications: [testPublication(uuid: dto.uuid, count: 5)],
        deletes: [DeleteDto(uuid: dto.uuid, version: testVersion(1, 'd-peer'))],
      ));

      expect(pubs().query(ObPublication_.uuid.equals(dto.uuid)).build().findFirst(),
          isNull);
      expect(chunks().count(), 0);
    });

    test('a second delete for the same uuid is not applied twice', () {
      final dto = testPublication(uuid: newUuidV7(), count: 2);
      applier.ingest(payloadOf([dto]));
      final delete =
          DeleteDto(uuid: dto.uuid, version: testVersion(20, 'd-peer'));

      applier.ingest(SyncPayload(publications: const [], deletes: [delete]));
      final second =
          applier.ingest(SyncPayload(publications: const [], deletes: [delete]));

      expect(second.deletesApplied, 0,
          reason: 'already dead — re-applying would rewrite a tombstone');
    });

    test('a deleted publication is not resurrected by a later push', () {
      final uuid = newUuidV7();
      applier.ingest(payloadOf([testPublication(uuid: uuid, count: 3)]));
      applier.ingest(SyncPayload(
        publications: const [],
        deletes: [DeleteDto(uuid: uuid, version: testVersion(20, 'd-peer'))],
      ));

      // The peer re-sends at a version far above the delete.
      applier.ingest(payloadOf([
        testPublication(uuid: uuid, count: 3, version: testVersion(9999, 'd-peer')),
      ]));

      expect(pubs().query(ObPublication_.uuid.equals(uuid)).build().findFirst(),
          isNull);
    });
  });

  group('the seven sites, through ingest', () {
    test('AC6: a full ingest leaves every reference consistent', () {
      final dto = testPublication(uuid: newUuidV7(), count: 3);
      applier.ingest(payloadOf([dto]));

      final publication = pubByUuid(dto.uuid);
      final document = docs().get(publication.document.targetId)!;
      expect(document.publicationId, publication.id, reason: 'site 3');
      expect(document.publication.targetId, publication.id, reason: 'site 4');
      expect(publication.chunks.length, 3, reason: 'site 7');
      expect(publication.notebooks, hasLength(1), reason: 'site 5');
      for (final chunk in chunks().getAll()) {
        expect(chunk.publicationId, chunk.publication.targetId, reason: 'sites 1/2');
      }
    });

    test('a notebook the payload omits is detached', () {
      final kept = newUuidV7();
      final dropped = newUuidV7();
      final dto = testPublication(
          uuid: newUuidV7(), count: 1, notebookUuids: [kept, dropped]);
      applier.ingest(payloadOf([dto]));

      applier.ingest(payloadOf([
        testPublication(
          uuid: dto.uuid,
          count: 1,
          notebookUuids: [kept],
          version: testVersion(40, 'd-peer'),
        ),
      ]));

      final droppedBook =
          books().query(ObNotebook_.uuid.equals(dropped)).build().findFirst()!;
      expect(droppedBook.publications, isEmpty,
          reason: 'the payload’s notebook list is authoritative when the '
              'metadata version wins; an omitted notebook is detached');
      expect(pubByUuid(dto.uuid).notebooks, hasLength(1));
    });
  });

  group('encoded payloads', () {
    test('ingestEncoded round-trips through the codec', () async {
      final dto = testPublication(uuid: newUuidV7(), count: 3);
      final encoded = encodePayload(payloadOf([dto]));

      final result = await applier.ingestEncoded(encoded);

      expect(result.publicationsApplied, 1);
      expect(pubByUuid(dto.uuid).chunkCount, 3);
    });
  });

  group('large sets', () {
    test('a 256-chunk set lands intact', () {
      final dto = testPublication(uuid: newUuidV7(), count: 256);
      applier.ingest(payloadOf([dto]));
      expect(chunks().count(), 256);
      expect(pubByUuid(dto.uuid).chunkCount, 256);
      for (final chunk in chunks().getAll()) {
        expect(chunk.publicationId, chunk.publication.targetId);
      }
    });
  });
}

/// A deterministic chunk draft, for seeding local state.
ChunkDraft draft(int index, {int seed = 0}) => ChunkDraft(
      chunkIndex: index,
      content: 'local chunk $index',
      tokenCount: 4,
      embedding: _seededVector(seed + index),
    );

List<double> _seededVector(int seed) {
  final random = Random(seed);
  final values = List<double>.filled(256, 0);
  for (var i = 0; i < 256; i++) {
    values[i] = random.nextDouble() - 0.5;
  }
  final norm = sqrt(values.fold<double>(0, (a, b) => a + b * b));
  return values.map((v) => v / norm).toList();
}
